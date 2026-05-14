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
        /limine.conf; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

# List all installed flow-iosched kernel versions by scanning /boot
list_installed() {
    local versions=()
    for f in /boot/vmlinuz-linux-flow-*; do
        if [ -f "$f" ]; then
            local ver="${f#/boot/vmlinuz-linux-flow-}"
            versions+=("$ver")
        fi
    done
    printf '%s\n' "${versions[@]}"
}

# Get the version of the currently-booted kernel
running_version() {
    uname -r | sed 's/-.*//'
}

# Remove a single kernel version
remove_version() {
    local version="$1"
    local running
    running=$(running_version)

    # Never remove the running kernel
    if [ "$version" = "$running" ]; then
        die "Cannot remove kernel $version — it is the currently-booted kernel."
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

    # Remove Limine entries
    local limine_conf
    limine_conf=$(find_limine_conf)
    if [ -n "$limine_conf" ]; then
        local entry_title="Flow I/O Scheduler (${version})"
        local fallback_title="Flow I/O Scheduler ${version} (fallback)"

        # Escape dots for sed
        local escaped_title
        escaped_title="$(printf '%s\n' "$entry_title" | sed 's/\./\\./g')"
        local escaped_fallback
        escaped_fallback="$(printf '%s\n' "$fallback_title" | sed 's/\./\\./g')"

        if grep -qF "/$entry_title" "$limine_conf" 2>/dev/null; then
            sed -i "/^\/$escaped_title/,/^\/[^/]/{ /^\/[^/]/!d; /^\/$escaped_title/d; }" "$limine_conf"
            info "Removed Limine entry: $entry_title"
        fi
        if grep -qF "/$fallback_title" "$limine_conf" 2>/dev/null; then
            sed -i "/^\/$escaped_fallback/,/^\/[^/]/{ /^\/[^/]/!d; /^\/$escaped_fallback/d; }" "$limine_conf"
            info "Removed Limine entry: $fallback_title"
        fi
    fi

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
            for v in "${versions[@]}"; do
                local running
                running=$(running_version)
                if [ "$v" = "$running" ]; then
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
        for v in "${versions[@]}"; do
            local running
            running=$(running_version)
            if [ "$v" = "$running" ]; then
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
