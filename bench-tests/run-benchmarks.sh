#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# I/O scheduler benchmark runner.
#
# Compares flow-iosched against mq-deadline, kyber, bfq, and adios
# using fio across five workloads.  Results are written to results/
# as CSV files.

set -euo pipefail

FIO="${FIO:-fio}"
RESULTS_DIR="results"
DEVICE="${DEVICE:?ERROR: DEVICE must be set to a dedicated test block device (e.g. DEVICE=/dev/nvme1n1)}"
SCHEDULERS="${SCHEDULERS:-none mq-deadline kyber bfq adios flow-iosched}"
NUM_JOBS=8
RUNTIME=30

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

# ── Safety: reject devices with mounted partitions ───────────────────
if lsblk -n -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "ERROR: $DEVICE (or a partition on it) has mounted filesystems." >&2
    echo "  Refusing to run benchmarks on an active device." >&2
    echo "  Use a dedicated test device with no mounted partitions." >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

echo "I/O Scheduler Benchmarks"
echo "========================"
echo "Device: $DEVICE"
echo "Runtime: ${RUNTIME}s per test"
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
    # Check that the scheduler exists
    if ! grep -q "$sched" /sys/block/$(basename "$DEVICE")/queue/scheduler 2>/dev/null; then
        echo "  [${sched}] SKIPPED — not available on this kernel"
        continue
    fi

    bench "randread_4k"   "4k"  32  100  "$sched"
    bench "randwrite_4k"  "4k"  32  0    "$sched"
    bench "seqread_128k"  "128k" 8  100  "$sched"
    bench "seqwrite_128k" "128k" 8  0    "$sched"
    bench "mixed_70_30"   "4k"  8   70   "$sched"

    # Extract summary row
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
    sys.exit(1)" 2>/dev/null) || {
            continue
        }
        read_lat=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['read']['lat_ns']['mean'] / 1000)
except Exception:
    sys.exit(1)" 2>/dev/null) || {
            continue
        }
        write_lat=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
    print(d['jobs'][0]['write']['lat_ns']['mean'] / 1000)
except Exception:
    sys.exit(1)" 2>/dev/null) || {
            continue
        }

        echo "$sched,$wl,$read_iops,$write_iops,$read_lat,$write_lat" \
            >> "$RESULTS_DIR/summary.csv"
    done
done

echo ""
echo "Done.  Results in $RESULTS_DIR/summary.csv"
echo "Generate charts: python3 plot-results.py"
