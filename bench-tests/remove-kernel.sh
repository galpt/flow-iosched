#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# remove-kernel.sh — Safely remove flow-iosched test kernels
#
# Usage:
#   ./remove-kernel.sh <version>
#   ./remove-kernel.sh --list
#   ./remove-kernel.sh --all
#
# Examples:
#   ./remove-kernel.sh 7.0.5    # Remove kernel 7.0.5 test install
#   ./remove-kernel.sh --list   # List installed flow-iosched kernels
#   ./remove-kernel.sh --all    # Remove all flow-iosched test kernels
#
# Safety:
#   - Will NOT remove the currently-booted kernel
#   - Will NOT touch the default kernel (e.g. vmlinuz-linux-cachyos)
#   - Prompts for confirmation before removal
#   - Removes boot files, Limine entries, and modules
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

err() { echo "ERROR: $*" >&2; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

die() {
    err "$*"
    exit 1
}

# Locate the Limine configuration file
find_limine_conf() {
    for candidate in \
        /boot/limine/limine.conf \
        /boot/limine.conf \
        /limine/limine.conf \
        /limine.conf \
        /efi/limine/limine.conf; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

# Remove all flow-iosched entries from a Limine config file
remove_flow_limine_entries() {
    local limine_conf="$1"
    if [ ! -f "$limine_conf" ]; then
        return 1
    fi
    if ! grep -q "Flow I/O Scheduler" "$limine_conf" 2>/dev/null; then
        return 0
    fi
    info "Removing flow-iosched entries from $limine_conf ..."
    awk '/^\/Flow I\/O Scheduler/ { skip = 1; next }
         skip && /^\//             { skip = 0 }
         !skip' "$limine_conf" > "${limine_conf}.tmp" && \
        mv "${limine_conf}.tmp" "$limine_conf"
}

# List all installed flow-iosched kernel versions by scanning /boot
list_installed() {
    local versions=()
    local ver
    for f in /boot/vmlinuz-linux-flow-* /boot/config-*-flow; do
        if [ -f "$f" ]; then
            case "$f" in
                /boot/vmlinuz-linux-flow-*)
                    ver="${f#/boot/vmlinuz-linux-flow-}"
                    ;;
                /boot/config-*-flow)
                    ver="${f#/boot/config-}"
                    ver="${ver%-flow}"
                    ;;
            esac
            versions+=("$ver")
        fi
    done
    # Deduplicate and sort
    printf '%s\n' "${versions[@]}" | sort -uV
}

# Get the full version of the currently-booted kernel (e.g. 7.0.5-2-cachyos or 7.0.5-flow)
running_version() {
    uname -r
}

# Remove a single kernel version
remove_version() {
    local version="$1"
    local running
    running=$(running_version)

    # Never remove the running kernel — but only if it's actually a flow-iosched kernel
    if [[ "$running" == *-flow* ]] && [ "${version}" = "$(echo "$running" | sed 's/-.*//')" ]; then
        warn "Skipping kernel $version — it is the currently-booted flow-iosched kernel."
        return 1
    fi

    local vmlinuz="/boot/vmlinuz-linux-flow-${version}"
    local config="/boot/config-${version}-flow"
    local initramfs="/boot/initramfs-linux-flow-${version}.img"
    local modules_dir="/lib/modules/${version}-flow"

    local found=false

    # Check what exists
    [ -f "$vmlinuz" ] && found=true
    [ -f "$config" ] && found=true
    [ -f "$initramfs" ] && found=true
    [ -d "$modules_dir" ] && found=true

    if [ "$found" = false ]; then
        warn "No flow-iosched installation found for kernel $version"
        # Still try to clean Limine entries
        remove_flow_limine_entries "$(find_limine_conf)" || true
        return 0
    fi

    # Show what will be removed
    echo "The following will be removed for kernel ${version}:"
    [ -f "$vmlinuz" ] && echo "  - $vmlinuz"
    [ -f "$config" ] && echo "  - $config"
    [ -f "$initramfs" ] && echo "  - $initramfs"
    [ -d "$modules_dir" ] && echo "  - $modules_dir (kernel modules)"

    # Confirm
    echo ""
    echo -n "Remove these files? [y/N] "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Cancelled."
        return 0
    fi

    # Remove boot files
    rm -f "$vmlinuz"
    rm -f "$config"
    rm -f "$initramfs"

    # Remove modules
    if [ -d "$modules_dir" ]; then
        rm -rf "$modules_dir"
    fi

    # Remove Limine entries (all flow-iosched entries, regardless of version)
    remove_flow_limine_entries "$(find_limine_conf)" || true

    echo ""
    info "Kernel $version removed successfully."
}

# ── Main logic ────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: $0 <version|--list|--all>"
    echo ""
    echo "  ./remove-kernel.sh 7.0.5    # Remove kernel 7.0.5"
    echo "  ./remove-kernel.sh --list   # List installed versions"
    echo "  ./remove-kernel.sh --all    # Remove all versions"
    echo ""
    echo "The currently-booted kernel can never be removed."
    exit 1
fi

case "${1}" in
    --list)
        versions=($(list_installed))
        if [ ${#versions[@]} -eq 0 ]; then
            echo "No flow-iosched test kernels installed."
        else
            echo "Installed flow-iosched kernels:"
            local running
            running=$(running_version)
            for v in "${versions[@]}"; do
                if [[ "$running" == *-flow* ]] && [ "${v}" = "$(echo "$running" | sed 's/-.*//')" ]; then
                    echo "  $v (currently booted — cannot remove)"
                else
                    echo "  $v"
                fi
            done
        fi
        exit 0
        ;;
    --all)
        versions=($(list_installed))
        if [ ${#versions[@]} -eq 0 ]; then
            echo "No flow-iosched test kernels installed."
            exit 0
        fi
        echo "The following kernels will be removed:"
        local running
        running=$(running_version)
        for v in "${versions[@]}"; do
            if [[ "$running" == *-flow* ]] && [ "${v}" = "$(echo "$running" | sed 's/-.*//')" ]; then
                echo "  $v (SKIPPED — currently booted)"
            else
                echo "  $v"
            fi
        done
        echo ""
        echo -n "Remove these kernels? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Cancelled."
            exit 0
        fi
        for v in "${versions[@]}"; do
            remove_version "$v" 2>&1 || true
        done
        echo ""
        info "All removable kernels cleaned up."
        exit 0
        ;;
    *)
        remove_version "${1}"
        ;;
esac
