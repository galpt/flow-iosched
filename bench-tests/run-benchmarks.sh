#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# I/O scheduler benchmark runner.
#
# Compares flow-iosched against other available schedulers using fio
# across five workloads.  Results are written to results/ as CSV files.
#
# Uses null_blk (virtual RAM device) by default — safe for scheduler
# comparisons without risking real data.  For real hardware measurements,
# override DEVICE:
#   DEVICE=/dev/nvme1n1 sudo ./bench-tests/run-benchmarks.sh
#
# See the README for what null_blk numbers mean vs physical devices.

set -euo pipefail

FIO="${FIO:-fio}"
RESULTS_DIR="results"
RUNTIME="${RUNTIME:-30}"
NUM_JOBS=8

# ── Check dependencies ────────────────────────────────────────────────
if ! command -v "$FIO" &>/dev/null; then
    echo "ERROR: fio (flexible I/O tester) is not installed." >&2
    echo "  Install with: sudo pacman -S fio" >&2
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is not installed (needed for results extraction)." >&2
    echo "  Install with: sudo pacman -S python" >&2
    exit 1
fi

# ── Resolve device ────────────────────────────────────────────────────
# Default to null_blk if not specified (safe for scheduler development)
DEVICE="${DEVICE:-/dev/nullb0}"

# If using null_blk, auto-load and set up cleanup
NULLBLK_CLEANUP=false
if [[ "$DEVICE" == /dev/nullb* ]] || [[ "$DEVICE" == nullb* ]]; then
    DEVICE="/dev/nullb0"
    # Only load if not already present
    if ! lsblk | grep -q nullb0 2>/dev/null; then
        echo "Loading null_blk module for synthetic benchmarking..."
        sudo modprobe null_blk nr_devices=1
    else
        echo "null_blk already loaded."
    fi
    NULLBLK_CLEANUP=true
    # Wait for device to appear
    for i in $(seq 1 10); do
        [ -b "$DEVICE" ] && break
        sleep 0.5
    done
fi

cleanup() {
    if $NULLBLK_CLEANUP; then
        echo "Unloading null_blk..."
        sudo modprobe -r null_blk 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Safety: reject devices with mounted partitions (skip for null_blk) ─
if ! $NULLBLK_CLEANUP; then
    if lsblk -n -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
        echo "ERROR: $DEVICE (or a partition on it) has mounted filesystems." >&2
        echo "  Refusing to run benchmarks on an active device." >&2
        exit 1
    fi
fi

mkdir -p "$RESULTS_DIR"

# Write metadata for chart annotations
if [[ "$DEVICE" == /dev/nullb0 ]]; then
    DEVICE_LABEL="null_blk (synthetic RAM device)"
else
    DEVICE_LABEL="$DEVICE"
fi
cat > "$RESULTS_DIR/metadata.txt" <<-EOF
device=$DEVICE
label=$DEVICE_LABEL
runtime=${RUNTIME}
null_blk=$NULLBLK_CLEANUP
EOF

echo "I/O Scheduler Benchmarks"
echo "========================"
echo "Device:   $DEVICE_LABEL"
echo "Runtime:  ${RUNTIME}s per test"
echo ""

# Auto-load flow-iosched module if available on disk (done before sysfs scan)
FLOW_IOSCHED_LOADED=false
if modinfo -n flow-iosched &>/dev/null; then
    if ! lsmod 2>/dev/null | grep -q "^flow_iosched "; then
        echo "  flow-iosched module found — loading..."
        sudo modprobe flow-iosched 2>/dev/null && FLOW_IOSCHED_LOADED=true || \
            echo "  flow-iosched: modprobe failed (module may need rebuilding for kernel $(uname -r))"
    else
        FLOW_IOSCHED_LOADED=true
    fi
fi

# Build scheduler list dynamically from what's available
SCHEDULERS="${SCHEDULERS:-}"
if [ -z "$SCHEDULERS" ]; then
    for s in none mq-deadline kyber bfq adios flow-iosched; do
        if grep -qw "$s" /sys/block/$(basename "$DEVICE")/queue/scheduler 2>/dev/null; then
            SCHEDULERS="$SCHEDULERS $s"
        fi
    done
    SCHEDULERS="${SCHEDULERS# }"
fi
if [ "$FLOW_IOSCHED_LOADED" = true ]; then
    if grep -qw "flow-iosched" /sys/block/$(basename "$DEVICE")/queue/scheduler 2>/dev/null; then
        echo "  flow-iosched: available"
    else
        echo "  flow-iosched: module loaded but not registered as elevator for $DEVICE"
        echo "  (module was built for a different kernel version)"
    fi
fi

echo "Schedulers: $SCHEDULERS"
echo ""

bench() {
    local name="$1" bs="$2" iodepth="$3" rwmix="$4" scheduler="$5"
    local out="$RESULTS_DIR/${scheduler}_${name}.json"

    # Flush pending writes before switching schedulers
    sync
    sudo blockdev --flushbufs "$DEVICE" 2>/dev/null || true

    # Select scheduler
    echo "$scheduler" | sudo tee /sys/block/$(basename "$DEVICE")/queue/scheduler > /dev/null

    echo "  [${scheduler}] ${name} (bs=${bs}, depth=${iodepth}, mix=${rwmix}) ..."

    if ! sudo "$FIO" --name="${scheduler}_${name}" \
        --filename="$DEVICE" \
        --direct=1 \
        --ioengine=libaio \
        --rw=randrw \
        --rwmixread="$rwmix" \
        --bs="$bs" \
        --iodepth="$iodepth" \
        --numjobs="$NUM_JOBS" \
        --group_reporting=1 \
        --runtime="$RUNTIME" \
        --time_based=1 \
        --output-format=json \
        --output="$out"; then
        echo "  [${scheduler}] WARNING: fio failed for ${name}" >&2
    fi
}

# Header
echo "scheduler,workload,read_iops,write_iops,read_lat_us,write_lat_us" \
    > "$RESULTS_DIR/summary.csv"

for sched in $SCHEDULERS; do
    if ! grep -q "$sched" /sys/block/$(basename "$DEVICE")/queue/scheduler 2>/dev/null; then
        echo "  [${sched}] SKIPPED — not available on this kernel"
        continue
    fi

    bench "randread_4k"   "4k"  32  100  "$sched"
    bench "randwrite_4k"  "4k"  32  0    "$sched"
    bench "seqread_128k"  "128k" 8  100  "$sched"
    bench "seqwrite_128k" "128k" 8  0    "$sched"
    bench "mixed_70_30"   "4k"  8   70   "$sched"

    for wl in randread_4k randwrite_4k seqread_128k seqwrite_128k mixed_70_30; do
        f="$RESULTS_DIR/${sched}_${wl}.json"
        [ -f "$f" ] || continue

        read_iops=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['read']['iops'])
except Exception:
    sys.exit(1)" 2>/dev/null) || {
            echo "  [${sched}] WARNING: failed to extract iops from $f — skipping" >&2
            continue
        }
        write_iops=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['write']['iops'])
except Exception:
    sys.exit(1)" 2>/dev/null) || { continue; }
        read_lat=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['read']['lat_ns']['mean'] / 1000)
except Exception:
    sys.exit(1)" 2>/dev/null) || { continue; }
        write_lat=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['write']['lat_ns']['mean'] / 1000)
except Exception:
    sys.exit(1)" 2>/dev/null) || { continue; }

        echo "$sched,$wl,$read_iops,$write_iops,$read_lat,$write_lat" \
            >> "$RESULTS_DIR/summary.csv"
    done
done

echo ""
echo "Done.  Results in $RESULTS_DIR/summary.csv"
echo "Generate charts: python3 bench-tests/plot-results.py"
echo ""
if $NULLBLK_CLEANUP; then
    echo "null_blk device will be removed automatically on exit."
fi
