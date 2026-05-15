#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# install-flow-iosched.sh — Build, install, and permanently load flow-iosched
# as a standalone kernel module (no full kernel rebuild required).
#
# Usage:
#   sudo ./install-flow-iosched.sh              # build + install + enable
#   sudo ./install-flow-iosched.sh --remove     # disable + uninstall cleanly
#   sudo ./install-flow-iosched.sh --status     # show current state
#
# The script detects your running kernel's compiler (clang or gcc), finds or
# downloads a matching kernel source for the private block-layer headers that
# are not exported by distro kernel-headers packages, builds flow-iosched.ko,
# installs it to /lib/modules/<uname -r>/extra/, and sets it as the default
# I/O scheduler via a udev rule so it persists across reboots.
#
# Requirements: git, make, either gcc or clang, and internet access (to
# download a kernel source tarball if headers are not found locally).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLOCK_DIR="$REPO_DIR/block"
MODULE_NAME="flow-iosched"
MODULE_FILE="flow-iosched.ko"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'  # No Color
info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()   { echo -e "  ${RED}✗${NC} $*"; }
die()   { err "$*"; exit 1; }

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [--remove|--status]

  (no args)   Build, install, and enable flow-iosched as the default I/O scheduler.
  --remove    Remove flow-iosched and restore the previous default scheduler.
  --status    Show whether flow-iosched is installed, loaded, and active.
  -h, --help  Show this message.
EOF
    exit 0
}

# ── Ensure root ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)."
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
    echo "─── flow-iosched status ───"
    echo ""

    # Module file installed?
    local modpath="/lib/modules/$(uname -r)/extra/$MODULE_NAME.ko"
    if [ -f "$modpath" ]; then
        ok "Module installed at $modpath"
    else
        err "Module not installed"
    fi

    # Module loaded?
    if lsmod | grep -q "^${MODULE_NAME//-/_}"; then
        ok "Module loaded in kernel"
    else
        err "Module not loaded"
    fi

    # udev rule present?
    local udev_rule="/etc/udev/rules.d/90-flow-iosched.rules"
    if [ -f "$udev_rule" ]; then
        ok "udev rule present ($udev_rule)"
        # Check which scheduler active on common block devices
        for dev in /sys/block/nvme[0-9]* /sys/block/sd[a-z] /sys/block/vd[a-z] /sys/block/mmcblk[0-9]*; do
            [ -f "$dev/queue/scheduler" ] || continue
            local current
            current=$(cat "$dev/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
            local devname
            devname=$(basename "$dev")
            echo "  $devname: $current"
        done
    else
        err "udev rule not present — flow-iosched will not be the default after reboot"
    fi

    # Kernel module params (sysfs) — only if flow-iosched is the active scheduler
    local sched_active
    sched_active=$(cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null | grep -o 'flow-iosched' || true)
    if [ -n "$sched_active" ] && [ -d "/sys/block/nvme0n1/queue/iosched" ]; then
        echo ""
        echo "─── flow-iosched sysfs tunables (nvme0n1) ───"
        for attr in /sys/block/nvme0n1/queue/iosched/*; do
            local val
            val=$(cat "$attr" 2>/dev/null) || continue
            printf "  %-30s = %s\n" "$(basename "$attr")" "$val"
        done
    fi

    exit 0
}

# ── Find kernel source for private block headers ──────────────────────────────
find_kernel_source() {
    local kv
    # Strip everything after the first non-version suffix.
    # e.g. 7.0.8-1-cachyos → 7.0.8,  6.18.5-arch1 → 6.18.5
    kv="$(uname -r | sed 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/')"

    # Fallback: if sed didn't match, use the running kernel version directly
    if [ "$kv" = "$(uname -r)" ]; then
        kv="$(uname -r | sed 's/-.*//')"   # cruder fallback
    fi

    # 1. Check if the build tree has the headers we need
    if [ -f "/lib/modules/$(uname -r)/build/block/blk-mq.h" ]; then
        KERNEL_BLOCK="/lib/modules/$(uname -r)/build/block"
        ok "Found kernel block headers in build tree: $KERNEL_BLOCK"
        return 0
    fi

    # 2. Check if a local kernel source cache exists (from build-kernel.sh)
    local cached="$SCRIPT_DIR/tmp/kernels"
    for dir in "$cached"/linux-*/block; do
        if [ -f "$dir/blk-mq.h" ]; then
            KERNEL_BLOCK="$dir"
            ok "Found kernel source in cache: $KERNEL_BLOCK"
            return 0
        fi
    done

    # 3. Check common source locations
    for dir in /usr/src/linux-* /usr/src/kernels/*; do
        if [ -f "$dir/block/blk-mq.h" ]; then
            KERNEL_BLOCK="$dir/block"
            ok "Found kernel source at $KERNEL_BLOCK"
            return 0
        fi
    done

    # 4. Prompt to download a matching kernel source
    local kv_major
    kv_major="${kv%%.*}"    # e.g. 7
    if [[ "$kv" =~ ^([0-9]+\.[0-9]+) ]]; then
        kv_major="${BASH_REMATCH[1]}"
    fi

    echo ""
    warn "Kernel block-layer headers not found locally."
    warn "flow-iosched needs internal headers (blk-mq.h, blk.h, etc.)"
    warn "that are not exported by distro kernel-headers packages."
    echo ""
    echo "  The script can download kernel $kv from kernel.org to obtain them."
    echo "  This is a one-time download (~210 MB, cached at $cached/)."
    echo ""

    read -r -p "Download kernel source to get the required headers? [Y/n] " reply
    case "$reply" in
        [nN]*)
            die "Cannot proceed without kernel source.  Install manually."
            ;;
        *)
            # Use the kv as the version to download, falling back to 7.0.8
            local ver="${kv:-7.0.8}"
            local major="${ver%%.*}"          # e.g. 7
            local url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${ver}.tar.xz"
            local tarball="$cached/linux-${ver}.tar.xz"
            local extract_dir="$cached/linux-${ver}"

            mkdir -p "$cached"
            info "Downloading $url ..."
            wget -q --show-progress "$url" -O "$tarball" || die "Download failed."

            info "Extracting ..."
            tar xf "$tarball" -C "$cached" || die "Extraction failed."

            KERNEL_BLOCK="$extract_dir/block"
            if [ ! -f "$KERNEL_BLOCK/blk-mq.h" ]; then
                die "Kernel source extracted but block/blk-mq.h not found."
            fi
            ok "Kernel source ready at $KERNEL_BLOCK"
            ;;
    esac
}

# ── Detect build tools ────────────────────────────────────────────────────────
detect_toolchain() {
    KERNEL_CC=""
    # Check what compiler was used to build the running kernel
    if [ -f "/lib/modules/$(uname -r)/build/scripts/cc-version.sh" ]; then
        local compiler_type
        compiler_type=$(grep -o 'clang\|gcc' "/lib/modules/$(uname -r)/build/.config" 2>/dev/null || true)
        if echo "$compiler_type" | grep -q clang; then
            KERNEL_CC="clang"
            # Check which specific clang is available
            for c in clang clang-22 clang-21 clang-20 clang-19 clang-18 clang-17; do
                if command -v "$c" &>/dev/null; then
                    CC="$c"
                    break
                fi
            done
            [ -z "$CC" ] && die "Kernel built with clang but no clang found. Install clang."
            # Check linker
            for l in ld.lld lld; do
                if command -v "$l" &>/dev/null; then
                    LD="$l"
                    break
                fi
            done
            [ -z "$LD" ] && die "Kernel built with clang but no lld found. Install lld."
        fi
    fi

    if [ -z "$CC" ]; then
        CC="gcc"
        LD="ld"
        if ! command -v gcc &>/dev/null; then
            die "gcc not found. Install build-essential/base-devel."
        fi
    fi

    ok "Build tools: CC=$CC, LD=$LD"
}

# ── Build the module ──────────────────────────────────────────────────────────
build_module() {
    cd "$BLOCK_DIR"

    info "Building $MODULE_NAME.ko ..."

    local build_log
    build_log=$(mktemp)

    if ! make -C "/lib/modules/$(uname -r)/build" \
        M="$BLOCK_DIR" \
        CONFIG_MQ_IOSCHED_FLOW=m \
        CC="$CC" \
        LD="$LD" \
        KCFLAGS="-I$KERNEL_BLOCK" \
        modules > "$build_log" 2>&1; then
        cat "$build_log" | tail -20
        die "Build failed (see above)."
    fi

    if [ ! -f "$MODULE_FILE" ]; then
        die "Build succeeded but $MODULE_FILE not found."
    fi

    ok "$MODULE_NAME.ko built ($(du -h "$MODULE_FILE" | cut -f1))"
}

# ── Install the module into the running kernel's module tree ──────────────────
install_module() {
    local mod_dir="/lib/modules/$(uname -r)/extra"
    mkdir -p "$mod_dir"

    cp "$BLOCK_DIR/$MODULE_FILE" "$mod_dir/"
    chmod 644 "$mod_dir/$MODULE_NAME.ko"

    # Generate module dependencies
    depmod -a

    ok "Module installed to $mod_dir/"
}

# ── Create udev rule to make flow-iosched the default scheduler ──────────────
install_udev() {
    local udev_file="/etc/udev/rules.d/90-flow-iosched.rules"

    cat > "$udev_file" << 'UDEVEOF'
# flow-iosched: set as the default I/O scheduler for block devices.
#
# Matches whole NVMe namespaces, SCSI/SATA disks, virtio disks, and
# MMC cards — but NOT partitions (e.g. nvme0n1p1, sda1) because those
# inherit the scheduler from their parent and have no queue/ directory.
#
# The kernel name patterns naturally exclude partitions:
#   nvme0n1 matches  nvme[0-9]*n[0-9]*   (whole namespace)
#   nvme0n1p1 doesn't match               (p1 left unconsumed by glob)
#   sda matches      sd[a-z]              (whole disk)
#   sda1 doesn't match                     (digits left unconsumed)
#
ACTION=="add|change", SUBSYSTEM=="block", \
    KERNEL=="nvme[0-9]*n[0-9]*|sd[a-z]|sd[a-z][a-z]|vd[a-z]*|mmcblk[0-9]*", \
    ATTR{queue/scheduler}="flow-iosched"
UDEVEOF

    # Reload udev and trigger for existing devices
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --type=devices --action=change -S block 2>/dev/null || true

    ok "udev rule installed: $udev_file"
}

# ── Load the module now ───────────────────────────────────────────────────────
load_module_now() {
    # Remove first if already loaded (e.g. after reinstalling)
    if lsmod | grep -q "^${MODULE_NAME//-/_}"; then
        modprobe -r "$MODULE_NAME" 2>/dev/null || true
    fi

    modprobe "$MODULE_NAME" 2>/dev/null || {
        insmod "/lib/modules/$(uname -r)/extra/$MODULE_FILE" 2>/dev/null || {
            die "Failed to load $MODULE_NAME. Check dmesg."
        }
    }

    ok "$MODULE_NAME loaded in kernel"
}

# ── Print post-install hints ──────────────────────────────────────────────────
print_success() {
    echo ""
    echo "────────────────────────────────────────────────────────────────"
    echo -e "  ${GREEN}flow-iosched is installed and enabled.${NC}"
    echo "────────────────────────────────────────────────────────────────"
    echo ""
    echo "  It is now the active scheduler on eligible block devices."
    echo "  This will persist across reboots via the installed udev rule."
    echo ""
    echo "  To check the current scheduler on each device:"
    echo "    sudo ./$(basename "$0") --status"
    echo ""
    echo "  To uninstall and restore the default:"
    echo "    sudo ./$(basename "$0") --remove"
    echo ""
    echo "  To see sysfs tunables:"
    echo "    ls /sys/block/<device>/queue/iosched/"
    echo ""
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
cmd_remove() {
    info "Removing flow-iosched ..."

    # 1. Remove udev rule
    local udev_file="/etc/udev/rules.d/90-flow-iosched.rules"
    if [ -f "$udev_file" ]; then
        rm -f "$udev_file"
        udevadm control --reload-rules 2>/dev/null || true
        # Trigger to restore the previous default scheduler
        udevadm trigger --type=devices --action=change -S block 2>/dev/null || true
        ok "Removed udev rule"
    fi

    # 2. Unload the module if loaded
    local modname="${MODULE_NAME//-/_}"
    if lsmod | grep -q "^$modname"; then
        # Switch all block devices back to the kernel default before unloading
        for dev in /sys/block/*/queue/scheduler; do
            if grep -q "flow-iosched" "$dev" 2>/dev/null; then
                # Pick the first available non-flow scheduler
                local alt
                alt=$(cat "$dev" | tr ' ' '\n' | grep -v 'flow\|\[\|\]' | head -1)
                [ -n "$alt" ] && echo "$alt" > "$dev" 2>/dev/null || true
            fi
        done
        modprobe -r "$modname" 2>/dev/null || rmmod "$modname" 2>/dev/null || true
        ok "Unloaded $MODULE_NAME from kernel"
    fi

    # 3. Remove module file
    local mod_path="/lib/modules/$(uname -r)/extra/$MODULE_NAME.ko"
    if [ -f "$mod_path" ]; then
        rm -f "$mod_path"
        depmod -a
        ok "Removed module file"
    fi

    echo ""
    ok "flow-iosched has been removed."
    echo "  Reboot or run 'sudo udevadm trigger' to restore the default scheduler on all devices."
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    -h|--help)
        usage
        ;;
    --status)
        cmd_status
        ;;
    --remove)
        check_root
        cmd_remove
        ;;
    --*)
        err "Unknown option: $1"
        usage
        ;;
    *)
    check_root
    detect_toolchain
    find_kernel_source
    build_module
    install_module
    load_module_now
    install_udev
    print_success
        ;;
esac
