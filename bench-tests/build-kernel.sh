#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build a kernel with flow-iosched integrated.
#
# Usage:
#   1. Place a matching kernel source tree at the path below.
#   2. Run this script to apply the patches and build.
#
# The resulting kernel will have flow-iosched available alongside
# mq-deadline, kyber, adios, bfq, and none.

set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-/usr/src/linux-cachyos}"
PATCH_DIR="${PATCH_DIR:-$(dirname "$0")/../patches}"
NUM_CORES="${NUM_CORES:-$(nproc)}"

if [ ! -d "$KERNEL_SRC/block" ]; then
    echo "Kernel source not found at $KERNEL_SRC"
    echo "Set KERNEL_SRC to point to a full kernel tree."
    echo ""
    echo "  # Example: fetch matching source"
    echo "  curl -L https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.5.tar.xz | tar xJ"
    echo "  export KERNEL_SRC=\$PWD/linux-7.0.5"
    exit 1
fi

# --- 1. Apply flow-iosched patches ---

echo "==> Applying 0001 (flow-iosched core + Kconfig + Makefile) ..."
cd "$KERNEL_SRC"
git am "$PATCH_DIR"/0001-linux7.0-flow-iosched-v1.0.0.patch 2>/dev/null || \
    patch -p1 < "$PATCH_DIR"/0001-linux7.0-flow-iosched-v1.0.0.patch

# Detect whether the compat patch is needed
if ! grep -q 'static int flow_init_sched.*elevator_queue \*eq' block/flow-iosched.c 2>/dev/null; then
    echo "==> Applying 0002 (6.12-compat init_sched) ..."
    git am "$PATCH_DIR"/0002-linux6.12-flow-iosched-compat.patch 2>/dev/null || \
        patch -p1 < "$PATCH_DIR"/0002-linux6.12-flow-iosched-compat.patch
fi

# --- 2. Configure ---

echo "==> Enabling CONFIG_MQ_IOSCHED_FLOW ..."
make olddefconfig
./scripts/config -e MQ_IOSCHED_FLOW
./scripts/config -d MQ_IOSCHED_DEFAULT_FLOW   # manual selection via sysfs

# --- 3. Build kernel ---

echo "==> Building kernel (${NUM_CORES} cores) ..."
make -j"$NUM_CORES" bzImage modules

# --- 4. Install ---

echo "==> Installing modules ..."
sudo make modules_install
sudo cp arch/x86/boot/bzImage /boot/vmlinuz-linux-flow
sudo mkinitcpio -k /boot/vmlinuz-linux-flow -g /boot/initramfs-linux-flow.img

echo ""
echo "Done.  Reboot and select flow-iosched at runtime:"
echo "  echo flow-iosched | sudo tee /sys/block/<dev>/queue/scheduler"
