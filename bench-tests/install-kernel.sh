#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "==> Requesting sudo (password prompt) ..."
    exec sudo "$0" "$@"
fi

HERE="$(dirname "$0")"
KERNEL_SRC="$HERE/linux-7.0.5"

echo "==> Installing modules to /lib/modules/ ..."
cd "$KERNEL_SRC"
make modules_install

echo "==> Installing kernel image ..."
cp -f arch/x86/boot/bzImage /boot/vmlinuz-linux-flow
cp -f .config /boot/config-7.0.5-flow

echo "==> Building initramfs ..."
mkinitcpio -k /boot/vmlinuz-linux-flow -g /boot/initramfs-linux-flow.img

echo "==> Registering kernel with kernel-install ..."
kernel-install add 7.0.5 /boot/vmlinuz-linux-flow 2>/dev/null || true

echo "==> Creating Limine entry ..."
limine-entry-tool --add-kernel "linux-flow" /boot/initramfs-linux-flow.img /boot/vmlinuz-linux-flow

echo ""
echo "=== Done ==="
echo "Boot entries now available:"
ls -1 /boot/loader/entries/
echo ""
echo "Reboot and select 'linux-flow' from the Limine boot menu."
echo "After booting, load the scheduler and run benchmarks:"
echo "  sudo modprobe flow-iosched"
echo "  cd ~/Desktop/Disk_D/sched-research/iosched/bench-tests"
echo "  sudo ./run-benchmarks.sh"
