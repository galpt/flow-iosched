#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# install-kernel.sh — Build and install a kernel with flow-iosched integrated,
# with automatic BLAKE2b hash handling for Limine bootloader.
#
# Re-running this script after the first install updates the kernel image
# and boot entry hashes, preventing the "Black2b hash does not match" panic.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "==> Requesting sudo ..."
    exec sudo "$0" "$@"
fi

HERE="$(dirname "$0")"
KERNEL_SRC="$HERE/linux-7.0.5"

if [ ! -d "$KERNEL_SRC" ]; then
    echo "ERROR: Kernel source directory not found at $KERNEL_SRC"
    echo "Extract or clone the kernel source to that path first."
    exit 1
fi

# ── Install kernel modules ───────────────────────────────────────────
echo "==> Installing modules to /lib/modules/ ..."
cd "$KERNEL_SRC"
make modules_install

# ── Install kernel image ─────────────────────────────────────────────
echo "==> Installing kernel image ..."
cp -f arch/x86/boot/bzImage /boot/vmlinuz-linux-flow
cp -f .config /boot/config-7.0.5-flow

# ── Build initramfs ──────────────────────────────────────────────────
echo "==> Building initramfs ..."
mkinitcpio -k /boot/vmlinuz-linux-flow -g /boot/initramfs-linux-flow.img

# ── Compute fresh BLAKE2b hashes ─────────────────────────────────────
echo "==> Computing BLAKE2b hashes ..."
KERNEL_HASH=$(b2sum /boot/vmlinuz-linux-flow | cut -d' ' -f1)
INITRD_HASH=$(b2sum /boot/initramfs-linux-flow.img | cut -d' ' -f1)
echo "  Kernel hash:   ${KERNEL_HASH}"
echo "  Initramfs hash: ${INITRD_HASH}"

# ── Register with kernel-install (if available) ──────────────────────
if command -v kernel-install &>/dev/null; then
    echo "==> Registering with kernel-install ..."
    kernel-install add 7.0.5 /boot/vmlinuz-linux-flow 2>/dev/null || true
fi

# ── Create / update Limine boot entry with correct hashes ────────────
echo "==> Setting up Limine boot entry ..."

# Locate the Limine configuration file (order matches Limine's scan order)
LIMINE_CONF=""
for candidate in \
    /boot/limine/limine.conf \
    /boot/limine.conf \
    /limine/limine.conf \
    /limine.conf; do
    if [ -f "$candidate" ]; then
        LIMINE_CONF="$candidate"
        break
    fi
done

ENTRY_TITLE="Flow I/O Scheduler (7.0.5)"

if [ -n "$LIMINE_CONF" ]; then
    # Remove any existing flow-iosched entry block (from previous runs)
    # The entry starts with "/Flow I/O Scheduler" and ends at the next "/"
    # or end of file
    if grep -q "^/$ENTRY_TITLE" "$LIMINE_CONF" 2>/dev/null; then
        echo "  Removing previous entry from $LIMINE_CONF ..."
        sed -i "/^\/$ENTRY_TITLE\$/,\${
            /^\/$ENTRY_TITLE\$/d
            /^\//q
        }" "$LIMINE_CONF" 2>/dev/null || \
        sed -i "/^\/$ENTRY_TITLE/,/^\/[^/]/ { /^\/$ENTRY_TITLE/d; /^\/[^/]/!d; }" "$LIMINE_CONF"
    fi

    # Append the new entry with current hashes.
    # The #hash suffix tells Limine to verify integrity at boot time.
    # Because we compute the hash immediately after installing the files,
    # the hash is guaranteed to match the file on disk.
    cat >> "$LIMINE_CONF" << EOF

/$ENTRY_TITLE
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-flow#${KERNEL_HASH}
    module_path: boot():/initramfs-linux-flow.img#${INITRD_HASH}
EOF
    echo "  Entry appended to $LIMINE_CONF with current BLAKE2b hashes."
else
    echo "  WARNING: No limine.conf found in standard locations."
    echo ""
    echo "  To create a Limine entry manually, add the following to your"
    echo "  limine configuration file:"
    echo ""
    echo "    /$ENTRY_TITLE"
    echo "        protocol: linux"
    echo "        kernel_path: boot():/vmlinuz-linux-flow#${KERNEL_HASH}"
    echo "        module_path: boot():/initramfs-linux-flow.img#${INITRD_HASH}"
    echo ""
fi

# ── Also add a no-hash fallback entry (for safety during updates) ────
# This entry does not include #hash suffixes, so it will always boot
# even if the file changes between script runs. Useful for recovery.
FALLBACK_TITLE="Flow I/O Scheduler (fallback — no hash check)"

if [ -n "$LIMINE_CONF" ]; then
    if ! grep -q "^/$FALLBACK_TITLE" "$LIMINE_CONF" 2>/dev/null; then
        cat >> "$LIMINE_CONF" << EOF

/$FALLBACK_TITLE
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-flow
    module_path: boot():/initramfs-linux-flow.img
EOF
        echo "  Fallback entry added (no hash check — safe for updates)."
    fi
fi

echo ""
echo "=== Done ==="
echo "Kernel installed. Reboot and select '$ENTRY_TITLE' from the Limine menu."
echo ""
echo "If you get a 'Black2b hash does not match' error, select the"
echo "fallback entry instead, then re-run this script to update hashes."
