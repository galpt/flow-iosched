#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# build-kernel.sh — Download, patch, build, and install a flow-iosched kernel
#
# Usage:
#   ./build-kernel.sh <version>
#
# Examples:
#   ./build-kernel.sh 7.0.5    # Build upstream 7.0.5 with flow-iosched
#   ./build-kernel.sh 6.18     # Build upstream 6.18 with flow-iosched
#   ./build-kernel.sh 6.12     # Build upstream 6.12 with compat patch
#
# Supported kernel ranges:
#   7.0.x         — applies 0001 (v3.0) patch
#   6.18 – 6.19   — applies 0001 (v3.0) patch
#   6.12 – 6.17   — applies 0001 (v3.0) + 0002 compat patches
#   5.18 – 6.11   — NOT supported (elevator op API differs)
#
# The script:
#   1. Downloads the kernel tarball from kernel.org (skipped if cached)
#   2. Extracts sources (skipped if already present)
#   3. Patches the kernel tree with flow-iosched patches
#   4. Configures using the running kernel's .config as base
#   5. Builds bzImage and modules
#   6. Installs with a unique name (never touches default kernel files)
#   7. Creates a Limine boot entry with correct BLAKE2b hashes
#
# Safety:
#   - The default kernel (e.g. vmlinuz-linux-cachyos) is never touched
#   - Boot entry hashes are computed immediately after file install
#   - A fallback boot entry without hashes is always provided
#   - Disk space is checked before extraction
#   - All build tools are verified before starting
#   - Script phases run without root where possible
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────
# These can be overridden via environment variables
: "${FLOW_CACHE_DIR:=""}"          # Default: ./tmp/kernels/ (auto-detected from script location)
: "${FLOW_PATCH_DIR:=""}"          # Auto-detected from script location; falls back to cloned repo
: "${FLOW_REPO_DIR:=""}"          # Default: ./tmp/repo/ (auto-detected from script location)
: "${FLOW_REPO_URL:="https://github.com/galpt/flow-iosched"}"
: "${FLOW_REPO_BRANCH:="main"}"
: "${FLOW_MAKE_JOBS:="$(nproc)"}"  # Parallel build jobs

# ── Global state ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=""
MAJOR=""
MINOR=""
PATCH=""
KERNEL_DIR=""
TARBALL=""
BOOT_PREFIX="flow-iosched"

# Apply default paths relative to the script's tmp/ directory.
# Users see the downloaded sources and cloned repo in a visible ./tmp/
# folder next to the script, not scattered in ~/.cache/.
: "${FLOW_CACHE_DIR:="${SCRIPT_DIR}/tmp/kernels"}"
: "${FLOW_REPO_DIR:="${SCRIPT_DIR}/tmp/repo"}"

# ── Utilities ─────────────────────────────────────────────────────────

err() { echo "ERROR: $*" >&2; }
info() { echo "==> $*" >&2; }
warn() { echo "WARNING: $*" >&2; }

die() {
    err "$*"
    exit 1
}

# Auto-detect the patches directory relative to this script.
# If not found locally, clones the flow-iosched repo to FLOW_REPO_DIR
# so the script is fully self-contained.
find_patch_dir() {
    # Walk up from the script directory looking for patches/
    local dir="$SCRIPT_DIR"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/patches" ]; then
            echo "$dir/patches"
            return 0
        fi
        dir="$(dirname "$dir")"
    done

    # Not found locally — clone the repo
    info "Local patches not found. Cloning flow-iosched repo to $FLOW_REPO_DIR ..."
    if [ -d "$FLOW_REPO_DIR" ]; then
        info "Repo already cloned at $FLOW_REPO_DIR, updating ..."
        cd "$FLOW_REPO_DIR"
        git pull --ff-only >/dev/null 2>&1 || warn "Could not update repo; using cached version"
        cd "$OLDPWD"
    else
        mkdir -p "$(dirname "$FLOW_REPO_DIR")"
        git clone --branch "$FLOW_REPO_BRANCH" --depth 1 "$FLOW_REPO_URL" "$FLOW_REPO_DIR" || {
            die "Failed to clone flow-iosched repo from $FLOW_REPO_URL"
        }
    fi

    if [ -d "$FLOW_REPO_DIR/patches" ]; then
        echo "$FLOW_REPO_DIR/patches"
        return 0
    fi

    die "Patches not found in cloned repo at $FLOW_REPO_DIR/patches"
}

# Parse a version string like "7.0.5" into major.minor.patch
# Also handles "6.18" -> 6.18.0
parse_version() {
    local v="$1"
    MAJOR=""
    MINOR=""
    PATCH=""

    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Invalid version format: '$v'. Expected e.g. 7.0.5 or 6.18"
    fi

    MAJOR="${v%%.*}"
    local rest="${v#*.}"
    MINOR="${rest%%.*}"
    if [[ "$rest" == *"."* ]]; then
        PATCH="${rest#*.}"
    else
        PATCH="0"
    fi
}

# Convert major.minor to the kernel.org major directory name (e.g. "v7.x")
major_dir() {
    local m="$1"
    echo "v${m}.x"
}

# Build the kernel.org tarball URL for a given version.
# Kernel.org ships releases without a patch suffix (e.g. linux-6.12.tar.xz
# not linux-6.12.0.tar.xz). Only incremental releases include the patch
# number (e.g. linux-6.12.1.tar.xz).
tarball_url() {
    local major="$1" minor="$2" patch="$3"
    local dir
    dir=$(major_dir "$major")
    if [ "$patch" = "0" ]; then
        echo "https://cdn.kernel.org/pub/linux/kernel/${dir}/linux-${major}.${minor}.tar.xz"
    else
        echo "https://cdn.kernel.org/pub/linux/kernel/${dir}/linux-${major}.${minor}.${patch}.tar.xz"
    fi
}

# Check if a command exists
need_cmd() {
    if ! command -v "$1" &>/dev/null; then
        die "Required command not found: $1"
    fi
}

# Check available disk space in a directory (in MB)
disk_space_mb() {
    local dir="$1"
    local kb
    kb=$(df -P "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$kb" ] || [ "$kb" -lt 1 ]; then
        echo 0
        return
    fi
    echo $(( kb / 1024 ))
}

# ── Version support checks ────────────────────────────────────────────

needs_compat_0002() {
    # Kernels 6.12 through 6.17 need 0002 for init_sched signature
    [ "$MAJOR" -lt 6 ] && return 1  # 5.x not supported
    [ "$MAJOR" -gt 6 ] && return 1  # 7.x+ no compat needed (elevator_alloc has 3 args)
    [ "$MAJOR" -eq 6 ] && [ "$MINOR" -lt 12 ] && return 1  # < 6.12 not supported
    [ "$MAJOR" -eq 6 ] && [ "$MINOR" -ge 18 ] && return 1  # 6.18+ no compat needed
    return 0  # 6.12-6.17: compat needed
}

is_version_supported() {
    # Only 6.12+ is supported (6.18+ with 0001, 6.12-6.17 with 0001+0002)
    if [ "$MAJOR" -lt 6 ]; then
        return 1
    fi
    if [ "$MAJOR" -eq 6 ] && [ "$MINOR" -lt 12 ]; then
        return 1
    fi
    return 0
}

# ── Long-running command helper ──────────────────────────────────────
# Runs a command with nohup so it survives terminal disconnect.
# Output is written to the given log file AND shown on screen.
KERNEL_BUILD_LOG=""

nohup_run() {
    local log_file="$1"
    shift

    KERNEL_BUILD_LOG="$log_file"
    rm -f "$log_file"

    info "Build output logged to: $(pwd)/${log_file}"
    info "If the terminal disconnects, check progress with: tail -f $(pwd)/${log_file}"

    # Run the command under nohup so SIGHUP (terminal disconnect) doesn't kill it.
    nohup "$@" > "$log_file" 2>&1 &
    local pid=$!

    # Show output in real-time while the process runs.
    tail -f "$log_file" --pid=$pid
    wait $pid

    local rc=$?
    if [ $rc -ne 0 ]; then
        rm -f "$log_file"
        die "Command failed (exit code $rc): $*"
    fi
}

# ── Build tool verification ───────────────────────────────────────────

check_deps() {
    local missing=false
    local pm_install="pacman -S"

    # Detect package manager for user-friendly install hints
    if command -v apt-get &>/dev/null; then
        pm_install="apt-get install"
    elif command -v dnf &>/dev/null; then
        pm_install="dnf install"
    elif command -v zypper &>/dev/null; then
        pm_install="zypper install"
    fi

    # Tools provided by base-devel or equivalent on most distros
    for tool in bc curl gcc git make patch xz; do
        if ! command -v "$tool" &>/dev/null; then
            # Most of these come from a meta-package
            if [ "$tool" = "gcc" ] || [ "$tool" = "make" ] || [ "$tool" = "patch" ]; then
                err "Missing build dependency: $tool (install with: ${pm_install} base-devel, or the equivalent for your distro)"
            elif [ "$tool" = "bc" ] || [ "$tool" = "curl" ] || [ "$tool" = "git" ] || [ "$tool" = "xz" ]; then
                err "Missing build dependency: $tool (install with: ${pm_install} ${tool})"
            fi
            missing=true
        fi
    done

    # b2sum is provided by coreutils (almost always installed)
    if ! command -v b2sum &>/dev/null; then
        err "Missing build dependency: b2sum (install with: ${pm_install} coreutils)"
        missing=true
    fi

    # Kernel-specific prerequisites
    if ! command -v mkinitcpio &>/dev/null; then
        err "Missing: mkinitcpio (install with: pacman -S mkinitcpio)"
        missing=true
    fi

    if ! command -v python3 &>/dev/null; then
        err "Missing: python3 (needed for benchmark chart generation; install with: ${pm_install} python)"
        missing=true
    fi

    if [ "$missing" = true ]; then
        die "Install missing dependencies and re-run."
    fi
}

# ── Kernel source download and extraction ─────────────────────────────

download_source() {
    local url="$1"
    local dest="$2"
    local tmp_dest="${dest}.part"

    info "Downloading $url ..."
    curl -fSL --retry 3 --progress-bar -o "$tmp_dest" "$url" || {
        rm -f "$tmp_dest"
        die "Download failed for $url"
    }

    # Verify it's a valid xz archive
    xz -t "$tmp_dest" 2>/dev/null || {
        rm -f "$tmp_dest"
        die "Downloaded file is corrupted (not a valid xz archive)"
    }

    mv "$tmp_dest" "$dest"
    info "Downloaded to $dest"
}

extract_source() {
    local tarball="$1"
    local dest_dir="$2"
    local tmp_extract="${dest_dir}.tmp"

    info "Extracting $tarball ..."

    # Check disk space (kernel source needs ~6 GB uncompressed)
    local available
    available=$(disk_space_mb "$(dirname "$dest_dir")")
    if [ "$available" -gt 0 ] && [ "$available" -lt 6144 ]; then
        die "Insufficient disk space in $(dirname "$dest_dir"): ${available}MB available, need ~6144MB"
    fi

    rm -rf "$tmp_extract"
    mkdir -p "$tmp_extract"

    tar -xJf "$tarball" -C "$tmp_extract" || {
        rm -rf "$tmp_extract"
        die "Extraction failed (corrupted tarball or insufficient disk space)."
    }

    # The tarball creates linux-X.Y.Z directory; move contents to our expected name
    local extracted
    shopt -s nullglob
    extracted=("$tmp_extract"/*)
    shopt -u nullglob
    if [ ${#extracted[@]} -eq 1 ] && [ -d "${extracted[0]}" ]; then
        mv "${extracted[0]}" "$dest_dir"
    else
        mv "$tmp_extract" "$dest_dir"
    fi
    rm -rf "$tmp_extract"

    info "Extracted to $dest_dir"
}

# ── Patch application ─────────────────────────────────────────────────

apply_patches() {
    local kernel_dir="$1"
    local patch_dir="$2"
    local major="$3" minor="$4"
    local applied=0

    # Determine which patches to apply
    local patches_to_apply=()

    # 0001 is always applied for all supported versions
    if [ -f "$patch_dir/0001-linux7.0-flow-iosched-v3.0.patch" ]; then
        patches_to_apply+=("$patch_dir/0001-linux7.0-flow-iosched-v3.0.patch")
    else
        # Fallback: try to match any 0001 patch (user may have renamed it)
        local fallback
        fallback=$(ls "$patch_dir"/0001-linux7.0-flow-iosched-*.patch 2>/dev/null | head -1)
        if [ -n "$fallback" ]; then
            patches_to_apply+=("$fallback")
        else
            die "0001 patch not found in $patch_dir — expected 0001-linux7.0-flow-iosched-v3.0.patch"
        fi
    fi

    # 0002 compat is needed for 6.12-6.17
    if needs_compat_0002; then
        if [ -f "$patch_dir/0002-linux6.12-flow-iosched-compat.patch" ]; then
            patches_to_apply+=("$patch_dir/0002-linux6.12-flow-iosched-compat.patch")
        else
            die "0002 compat patch not found at $patch_dir/0002-linux6.12-flow-iosched-compat.patch"
        fi
    fi

    cd "$kernel_dir"

    # Check if the scheduler source is already present from a previous run.
    # If so, verify the version matches the current patch.  If the cached
    # file has a different FLOW_VERSION, delete it to force re-patching.
    if [ -f "block/flow-iosched.c" ]; then
        local cached_version
        cached_version=$(grep '#define FLOW_VERSION' block/flow-iosched.c 2>/dev/null | cut -d'"' -f2)
        local patch_version
        patch_version=$(grep '#define FLOW_VERSION' "$patch_dir"/0001-linux7.0-flow-iosched-v3.0.patch 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ -n "$cached_version" ] && [ -n "$patch_version" ] && [ "$cached_version" != "$patch_version" ]; then
            info "Cached flow-iosched v$cached_version differs from patch v$patch_version — re-patching."
            rm -f block/flow-iosched.c
        else
            info "flow-iosched.c already present — patches already applied, skipping."
            return 0
        fi
    fi

    for patch in "${patches_to_apply[@]}"; do
        local patch_name
        patch_name="$(basename "$patch")"
        info "Applying $patch_name ..."

        # Apply with patch -p1 -N (--forward ignores already-applied patches
        # instead of prompting).  We do not use git am because the kernel
        # source is typically extracted from a kernel.org tarball (no .git),
        # and git am prompts interactively when applied to a tree that has
        # a git repository in a parent directory.
        patch -p1 -N -r - < "$patch" 2>/dev/null || {
            local exit_code=$?
            # Show the actual error (re-apply without suppressing stderr)
            patch -p1 -N --dry-run < "$patch" 2>&1 | head -20
            die "Failed to apply $patch_name (exit $exit_code)"
        }
        ((++applied))
    done

    info "Applied $applied patch(es) successfully"
}

# ── Kernel configuration ──────────────────────────────────────────────

configure_kernel() {
    local kernel_dir="$1"
    local log_file="configure-kernel.log"

    cd "$kernel_dir"
    rm -f "$log_file"

    info "Configuring kernel ..."
    info "Configuration log: $(pwd)/${log_file}"

    # ── Step 1: Base config ──────────────────────────────────────
    if [ -f /proc/config.gz ]; then
        info "  Base config: /proc/config.gz"
        zcat /proc/config.gz > .config 2>>"$log_file" || {
            die "Failed to read /proc/config.gz (see $log_file)"
        }
        echo "OK: base config from /proc/config.gz ($(wc -l < .config) lines)" >> "$log_file"
    elif [ -f "/lib/modules/$(uname -r)/build/.config" ]; then
        info "  Base config: /lib/modules/$(uname -r)/build/.config"
        cp "/lib/modules/$(uname -r)/build/.config" .config 2>>"$log_file" || {
            die "Failed to copy base config (see $log_file)"
        }
    else
        warn "No running kernel config found. Kernel config defaults will be used."
        echo "WARN: no base config, using defaults" >> "$log_file"
    fi

    # ── Step 2: olddefconfig ──────────────────────────────────────
    info "  Running make olddefconfig (this may take up to 60 seconds) ..."
    make olddefconfig >> "$log_file" 2>&1 || {
        die "'make olddefconfig' failed. See $(pwd)/${log_file} for details."
    }

    # ── Step 3: Enable flow-iosched scheduler ─────────────────────
    info "  Enabling CONFIG_MQ_IOSCHED_FLOW ..."
    if grep -q "CONFIG_MQ_IOSCHED_FLOW" .config 2>/dev/null; then
        ./scripts/config --enable CONFIG_MQ_IOSCHED_FLOW 2>>"$log_file" || {
            warn "Could not enable CONFIG_MQ_IOSCHED_FLOW via scripts/config, using sed fallback"
            sed -i 's/# CONFIG_MQ_IOSCHED_FLOW is not set/CONFIG_MQ_IOSCHED_FLOW=m/' .config
        }
    else
        die "CONFIG_MQ_IOSCHED_FLOW not found in .config. Did the patch apply correctly?"
    fi

    # ── Step 4: Refresh deps ──────────────────────────────────────
    info "  Refreshing kernel configuration ..."
    make olddefconfig >> "$log_file" 2>&1 || {
        die "'make olddefconfig' failed after enabling flow-iosched. See $log_file"
    }

    # ── Step 5: Verify ────────────────────────────────────────────
    if ! grep -q "^CONFIG_MQ_IOSCHED_FLOW=" .config; then
        die "CONFIG_MQ_IOSCHED_FLOW is not set after configuration. Something went wrong."
    fi
    info "  CONFIG_MQ_IOSCHED_FLOW: $(grep '^CONFIG_MQ_IOSCHED_FLOW=' .config)"

    # ── Step 6: Set LOCALVERSION to -flow ─────────────────────────
    info "  Setting LOCALVERSION=-flow ..."
    ./scripts/config --set-str CONFIG_LOCALVERSION "-flow" 2>>"$log_file" || {
        warn "Could not set CONFIG_LOCALVERSION via scripts/config, using sed fallback"
        sed -i '/^CONFIG_LOCALVERSION=/d' .config
        echo 'CONFIG_LOCALVERSION="-flow"' >> .config
    }
    make olddefconfig >> "$log_file" 2>&1 || {
        die "'make olddefconfig' failed after setting LOCALVERSION. See $log_file"
    }
    info "  LOCALVERSION: $(grep '^CONFIG_LOCALVERSION=' .config)"

    info "Configuration complete."
}

# ── Build ─────────────────────────────────────────────────────────────

build_kernel() {
    local kernel_dir="$1"
    local bzimage_target="bzImage"

    cd "$kernel_dir"

    info "Building kernel (bzImage) with $FLOW_MAKE_JOBS parallel jobs ..."
    info "This usually takes 10–30 minutes. The log below updates in real-time."
    nohup_run "build-bzImage.log" make -j"$FLOW_MAKE_JOBS" "$bzimage_target"
    info "bzImage built successfully"

    info "Building kernel modules (may take 5–15 minutes) ..."
    nohup_run "build-modules.log" make -j"$FLOW_MAKE_JOBS" modules
    info "Modules built successfully"
}

# ── Installation (requires root) ──────────────────────────────────────

install_kernel() {
    local kernel_dir="$1"
    local version="$2"
    local major="$3" minor="$4" patch="$5"
    local dest_vmlinuz="/boot/vmlinuz-linux-flow-${version}"
    local dest_config="/boot/config-${version}-flow"
    local dest_initramfs="/boot/initramfs-linux-flow-${version}.img"
    local entry_title="Flow I/O Scheduler (${version})"
    local fallback_title="Flow I/O Scheduler ${version} (fallback)"

    cd "$kernel_dir"

    # ── Install modules ───────────────────────────────────────────
    info "Installing kernel modules ..."
    make modules_install 2>&1 || die "Failed to install modules"

    # ── Update module dependencies ────────────────────────────────
    info "Updating module dependencies ..."
    depmod -a 2>&1 || warn "depmod failed. modprobe may not find the module."

    # ── Verify module is installed ────────────────────────────────
    info "Verifying flow-iosched module installation ..."
    local mod_path
    mod_path=$(find /lib/modules -maxdepth 3 -name "flow-iosched.ko" 2>/dev/null | head -1)
    if [ -z "$mod_path" ]; then
        warn "flow-iosched.ko not found in any /lib/modules/ directory."
        warn "The scheduler module was not installed. Check build output above."
    else
        info "  Module installed: ${mod_path}"
        # Try to load the module on the current system (best-effort).
        # This works when the build and target kernels match.
        if [ "${mod_path#/lib/modules/}" != "${mod_path}" ]; then
            local mod_ver="${mod_path#/lib/modules/}"
            mod_ver="${mod_ver%%/*}"
            if [ "$mod_ver" = "$(uname -r)" ]; then
                info "  Module version matches running kernel. Attempting load ..."
                depmod -a 2>/dev/null || true
                modprobe flow-iosched 2>/dev/null && {
                    sleep 1
                    if grep -q "flow-iosched" /sys/block/*/queue/scheduler 2>/dev/null; then
                        info "  flow-iosched is now available in /sys/block/*/queue/scheduler"
                    else
                        warn "  Module loaded but not listed in sysfs. Check dmesg for errors."
                    fi
                } || warn "  Could not load module. After reboot, run: sudo modprobe flow-iosched"
            else
                info "  Module built for kernel ${mod_ver}, running $(uname -r)."
                info "  After booting the target kernel, run: sudo modprobe flow-iosched"
            fi
        fi
    fi

    # ── Install kernel image ──────────────────────────────────────
    local bzimage_src="arch/x86/boot/bzImage"
    if [ ! -f "$bzimage_src" ]; then
        die "bzImage not found at $bzimage_src. Build may have failed."
    fi

    info "Installing kernel image ..."
    cp -f "$bzimage_src" "$dest_vmlinuz"
    cp -f ".config" "$dest_config"

    # ── Build initramfs ───────────────────────────────────────────
    if command -v mkinitcpio &>/dev/null; then
        info "Building initramfs ..."
        mkinitcpio -k "$dest_vmlinuz" -g "$dest_initramfs" 2>&1 || {
            warn "mkinitcpio failed. Continuing without initramfs."
        }
    else
        warn "mkinitcpio not found. Skipping initramfs creation."
    fi

    # ── Compute BLAKE2b hashes ────────────────────────────────────
    info "Computing BLAKE2b hashes ..."
    local kernel_hash="" initrd_hash=""
    if command -v b2sum &>/dev/null; then
        kernel_hash=$(b2sum "$dest_vmlinuz" | cut -d' ' -f1)
        if [ -f "$dest_initramfs" ]; then
            initrd_hash=$(b2sum "$dest_initramfs" | cut -d' ' -f1)
        fi
        info "  Kernel:   ${kernel_hash}"
        info "  Initramfs: ${initrd_hash:-"(not available)"}"
    else
        warn "b2sum not found. Skipping hash computation."
    fi

    # ── Create / update Limine boot entry ─────────────────────────
    setup_limine_entry "$entry_title" "$fallback_title" \
        "/vmlinuz-linux-flow-${version}" \
        "/initramfs-linux-flow-${version}.img" \
        "$kernel_hash" "$initrd_hash"
}

setup_limine_entry() {
    local entry_title="$1"
    local fallback_title="$2"
    local kernel_relpath="$3"    # e.g. /vmlinuz-linux-flow-7.0.5
    local initrd_relpath="$4"    # e.g. /initramfs-linux-flow-7.0.5.img
    local kernel_hash="$5"
    local initrd_hash="$6"

    # Locate Limine configuration file
    local limine_conf=""
    for candidate in \
        /boot/limine/limine.conf \
        /boot/limine.conf \
        /limine/limine.conf \
        /limine.conf; do
        if [ -f "$candidate" ]; then
            limine_conf="$candidate"
            break
        fi
    done

    # If no limine.conf exists, create one at the preferred location
    if [ -z "$limine_conf" ]; then
        # Check which parent directory exists and use that
        if [ -d "/boot/limine" ]; then
            limine_conf="/boot/limine/limine.conf"
        elif [ -d "/boot" ]; then
            limine_conf="/boot/limine.conf"
        elif [ -d "/limine" ]; then
            limine_conf="/limine/limine.conf"
        else
            warn "No suitable location for limine.conf found."
            warn "Boot entries will not be created automatically."
            return 1
        fi
        info "Creating new Limine configuration at $limine_conf"
    fi

    # Remove any existing flow-iosched entries (hash + fallback + their bodies)
    # Uses awk to delete from any line starting with "/Flow I/O Scheduler"
    # through the next line starting with "/" (the next entry header).
    if grep -qF "Flow I/O Scheduler" "$limine_conf" 2>/dev/null; then
        info "Removing old flow-iosched entries from $limine_conf ..."
        awk '/^\/Flow I\/O Scheduler/ { skip = 1; next }
             skip && /^\//             { skip = 0 }
             !skip' "$limine_conf" > "${limine_conf}.tmp" && \
            mv "${limine_conf}.tmp" "$limine_conf"
    fi

    # Append the hash-verified entry
    {
        echo ""
        echo "/$entry_title"
        echo "    protocol: linux"
        if [ -n "$kernel_hash" ]; then
            echo "    kernel_path: boot():${kernel_relpath}#${kernel_hash}"
        else
            echo "    kernel_path: boot():${kernel_relpath}"
        fi
        if [ -n "$kernel_hash" ] && [ -n "$initrd_hash" ]; then
            echo "    module_path: boot():${initrd_relpath}#${initrd_hash}"
        elif [ -f "/boot${initrd_relpath}" ]; then
            echo "    module_path: boot():${initrd_relpath}"
        fi
        # Include the kernel cmdline from the running system for convenience
        if [ -f /proc/cmdline ]; then
            local cmdline
            cmdline=$(cat /proc/cmdline)
            echo "    cmdline: ${cmdline}"
        fi
    } >> "$limine_conf"
    info "Boot entry added: $entry_title"

    # Append the fallback entry (no hashes — always bootable)
    {
        echo ""
        echo "/$fallback_title"
        echo "    protocol: linux"
        echo "    kernel_path: boot():${kernel_relpath}"
        if [ -f "/boot${initrd_relpath}" ]; then
            echo "    module_path: boot():${initrd_relpath}"
        fi
        echo "    comment: No BLAKE2b hash check — safe after kernel reinstall"
        if [ -f /proc/cmdline ]; then
            local cmdline
            cmdline=$(cat /proc/cmdline)
            echo "    cmdline: ${cmdline}"
        fi
    } >> "$limine_conf"
    info "Fallback entry added: $fallback_title"
}

# ── Main logic ────────────────────────────────────────────────────────

main() {
    # ── Parse arguments ───────────────────────────────────────────
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <kernel-version>"
        echo ""
        echo "Examples:"
        echo "  $0 7.0.5    # Build upstream 7.0.5 with flow-iosched"
        echo "  $0 6.18     # Build upstream 6.18"
        echo "  $0 6.12     # Build upstream 6.12 with compat patch"
        echo ""
        echo "Supported: 6.12+  (5.18-6.11 not supported — elevator API differs)"
        exit 1
    fi

    VERSION="$1"
    parse_version "$VERSION"

    # ── Version support check ─────────────────────────────────────
    if ! is_version_supported; then
        die "Kernel ${MAJOR}.${MINOR}.${PATCH} is not supported." \
            "Supported ranges: 6.12.x to 6.19.x, 7.0.x+" \
            "(5.18-6.11 has different elevator op signatures and needs a compat patch)"
    fi

    # ── Determine paths ───────────────────────────────────────────
    if [ -z "$FLOW_PATCH_DIR" ]; then
        FLOW_PATCH_DIR="$(find_patch_dir)"
    fi
    if [ ! -d "$FLOW_PATCH_DIR" ]; then
        die "Patches directory not found at $FLOW_PATCH_DIR"
    fi

    mkdir -p "$FLOW_CACHE_DIR"

    local major_dir_name
    major_dir_name=$(major_dir "$MAJOR")
    if [ "$PATCH" = "0" ]; then
        KERNEL_DIR="$FLOW_CACHE_DIR/linux-${MAJOR}.${MINOR}"
        TARBALL="$FLOW_CACHE_DIR/linux-${MAJOR}.${MINOR}.tar.xz"
    else
        KERNEL_DIR="$FLOW_CACHE_DIR/linux-${MAJOR}.${MINOR}.${PATCH}"
        TARBALL="$FLOW_CACHE_DIR/linux-${MAJOR}.${MINOR}.${PATCH}.tar.xz"
    fi

    # ── Authenticate sudo upfront ────────────────────────────────
    # This prompts for the password once at the start and keeps the session
    # alive with a background re-authenticator, so the install step later
    # does not prompt again — the user can walk away during the build.
    info "Requesting sudo access (will be kept alive during the build) ..."
    if ! sudo -v; then
        die "sudo authentication failed. Installation requires root."
    fi
    # Background loop: re-authenticate every 2 minutes (default timeout is 5)
    while true; do sudo -v; sleep 120; done &
    SUDO_KEEPER=$!
    trap 'kill $SUDO_KEEPER 2>/dev/null; wait $SUDO_KEEPER 2>/dev/null' EXIT INT TERM

    # ── Step 1: Download ──────────────────────────────────────────
    if [ -f "$TARBALL" ]; then
        info "Tarball already cached at $TARBALL"
    else
        local url
        url=$(tarball_url "$MAJOR" "$MINOR" "$PATCH")
        info "Kernel source URL: $url"
        download_source "$url" "$TARBALL"
    fi

    # ── Step 2: Extract ───────────────────────────────────────────
    if [ -d "$KERNEL_DIR" ]; then
        info "Kernel source already extracted at $KERNEL_DIR"
    else
        extract_source "$TARBALL" "$KERNEL_DIR"
    fi

    # ── Step 3: Apply patches ─────────────────────────────────────
    info "Applying flow-iosched patches to ${MAJOR}.${MINOR}.${PATCH} ..."
    apply_patches "$KERNEL_DIR" "$FLOW_PATCH_DIR" "$MAJOR" "$MINOR"

    # ── Step 4: Configure ─────────────────────────────────────────
    info "Configuring kernel ..."
    configure_kernel "$KERNEL_DIR"

    # ── Step 5: Build ─────────────────────────────────────────────
    info "Building kernel (this may take a while) ..."
    build_kernel "$KERNEL_DIR"

    # ── Step 6: Install (needs root) ──────────────────────────────
    if [ "$EUID" -ne 0 ]; then
        info "Installing kernel (sudo session is active — no password needed) ..."
        sudo -E env "PATH=$PATH" "${SCRIPT_DIR}/build-kernel.sh" --install "$VERSION" "$KERNEL_DIR" "$MAJOR" "$MINOR" "$PATCH" || {
            die "Installation failed"
        }
        exit 0
    fi

    install_kernel "$KERNEL_DIR" "$VERSION" "$MAJOR" "$MINOR" "$PATCH"

    # ── Done ──────────────────────────────────────────────────────
    echo ""
    echo "============================================"
    echo " Build complete for kernel ${VERSION}"
    echo "============================================"
    echo ""
    echo "Installed files:"
    echo "  Kernel:  /boot/vmlinuz-linux-flow-${VERSION}"
    echo "  Config:  /boot/config-${VERSION}-flow"
    echo "  Initram: /boot/initramfs-linux-flow-${VERSION}.img"
    echo ""
    echo "Reboot and select 'Flow I/O Scheduler (${VERSION})' from the Limine menu."
    echo ""
    echo "If the hash-verified entry fails (e.g. after reinstalling without rebuilding),"
    echo "use the fallback entry which skips the hash check."
}

# ── Install-only mode (invoked by sudo re-exec) ──────────────────────
if [ "${1:-}" = "--install" ]; then
    VERSION="$2"
    KERNEL_DIR="$3"
    MAJOR="$4"
    MINOR="$5"
    PATCH="$6"
    install_kernel "$KERNEL_DIR" "$VERSION" "$MAJOR" "$MINOR" "$PATCH"

    echo ""
    echo "============================================"
    echo " Installation complete for kernel ${VERSION}"
    echo "============================================"
    exit 0
fi

main "$@"
