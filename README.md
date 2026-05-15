# flow-iosched

Multi-lane I/O scheduler for the Linux block layer, adapted from the lane-based
budget and classification design of the
[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow)
CPU scheduler.

> [!NOTE]
> flow-iosched targets the same audience as its CPU-side inspiration: general-purpose
> desktop and workstation machines where responsiveness and throughput both matter.
> Version 2.0.0 brings the I/O scheduler up to parity with scx_flow's lane architecture
> including proportional budget refill, bounded signal decay, latency credit/debt
> tracking, per-process IO profiles, a starvation quota mechanism, and a 3-mode
> autotuner that eliminates the need for manual tuning.

## Overview

| Lane | Target I/O | Slice / Window | Behaviour |
|------|------------|----------------|-----------|
| Emergency | `BLK_MQ_INSERT_AT_HEAD` | Immediate | Bypasses all scheduling |
| Reserved | Synchronous reads, metadata | configurable (default 2048 sectors) | Low-latency path for interactive I/O |
| Latency | Small random I/O | Short batch window | Bounded responsiveness |
| Shared | Async writes, best-effort | Configurable batch limit | Background throughput |
| Contained | Hog-throttled processes | Reduced dispatch rate | Limits I/O-bound interference |

Dispatch priority: Emergency > Reserved > Latency > Shared > Contained.
Starvation counters rotate CPU-intensive I/O flows back into higher lanes so no
lane is abandoned entirely.

## Design

```mermaid
flowchart TB
    A1["1. I/O Request

A bio arrives from the blk-mq layer.
flow_prepare_request() allocates a
flow_rq_data struct from the mempool."]

    B1["2. Lane Classification

flow_assign_lane() inspects the request's
cmd_flags (sync, meta, flush, priority),
is_write, blk_rq_bytes, the per-process
budget, and insert_flags (AT_HEAD).
Returns a lane number (1-5) and deadline."]

    N3["3. Five Priority Lanes

Dispatch walks lanes in priority order:
Emergency > Reserved > Latency > Shared
> Contained. Each lane has its own
deadline-sorted rbtree (rb_root_cached)."]

    C1["Emergency

BLK_MQ_INSERT_AT_HEAD bypass.
Queued in prio_queue[0] for immediate,
unconditional dispatch. No rbtree."]

    D1["Reserved

Synchronous reads, REQ_META, and
REQ_PRIO. Budget: 2048 sectors.
Deadline = start_time_ns (FIFO order)."]

    E1["Latency

REQ_SYNC writes and small I/O <= 4 KB.
Deadline = start_time_ns + 2 ms.
Budget refills when idle > 100 ms."]

    F1["Shared

Async writes and best-effort I/O.
Budget: 512 sectors. Async depth
capped at nr_requests / 3."]

    G1["Contained

Processes with containment_score >= 100
(hog-throttled). Score decays by 8
on each idle refill tick."]

    H1["4. Per-hctx Dispatch

flow_dispatch_request(hctx):
Phase 1 (fast path): pops from
khd->dispatch_list with only the
per-hctx lock (no global contention).
Phase 2 (slow path): refills from
lane rbtrees under fd->lock, then
appends to the dispatch list.
QUEUE_FLAG_SQ_SCHED is cleared."]

    I1["5. Device

NVMe, SATA, or virtual device.
Multiple hardware queues."]

    J1["Budget & Containment

Per-process flow_icq_data via icq_size.
All fields are atomic (atomic64_t/atomic_t).
Primary refill: proportional (sectors / 100)
on every I/O completion (lock-free,
no fd->lock). Secondary refill on idle
> 100 ms. Budget < 0 raises containment
score via bounded CAS (max 100).
Score decays geometrically on each
completion. Latency allowance raised
on positive budget growth; latency
pressure raised on containment."]

    K1["Starvation & Quota Tracking

Per-hctx starvation_rounds[5] array.
When rounds >= starvation_max[lane],
force-dispatch from that lane.
Also: high_priority_burst_rounds counter.
When >= high_priority_quota_max (def 4),
forces lower-lane dispatch even before
starvation max is reached, then resets.
Default starvation thresholds:
Reserved = 5, Shared = 20, Contained = 30."]

    L1["ICQ Lifecycle

flow_init_icq() initialises budget to
2048 sectors (atomic64_set), all other
fields to 0 via atomic_set, and timestamps
via smp_store_release. flow_exit_icq()
resets each field atomically (no memset).
Both are NULL-guarded. Completion path
uses lock-free atomics; insertion path
also lock-free for per-ICQ fields."]

    A1 --> B1
    B1 --> N3
    N3 --> C1
    N3 --> D1
    N3 --> E1
    N3 --> F1
    N3 --> G1
    C1 --> H1
    D1 --> H1
    E1 --> H1
    F1 --> H1
    G1 --> H1
    H1 --> I1

    B1 -.-> J1
    J1 -.-> G1
    C1 -.-> K1
    D1 -.-> K1
    E1 -.-> K1
    F1 -.-> K1
    G1 -.-> K1
    K1 -.-> H1
    L1 -.-> J1

    style A1 fill:#eef2ff,stroke:#6366f1,stroke-width:2,color:#1e293b
    style B1 fill:#fff,stroke:#94a3b8,stroke-width:2,color:#1e293b
    style N3 fill:#fff,stroke:#64748b,stroke-width:2,color:#1e293b
    style C1 fill:#fff,stroke:#dc2626,stroke-width:2,color:#1e293b
    style D1 fill:#fff,stroke:#2563eb,stroke-width:2,color:#1e293b
    style E1 fill:#fff,stroke:#16a34a,stroke-width:2,color:#1e293b
    style F1 fill:#fff,stroke:#d97706,stroke-width:2,color:#1e293b
    style G1 fill:#fff,stroke:#9333ea,stroke-width:2,color:#1e293b
    style H1 fill:#f0f9ff,stroke:#0ea5e9,stroke-width:2,color:#1e293b
    style I1 fill:#fef2f2,stroke:#ef4444,stroke-width:2,color:#1e293b
    style J1 fill:#faf5ff,stroke:#a855f7,stroke-width:2,color:#1e293b
    style K1 fill:#fff7ed,stroke:#f59e0b,stroke-width:2,color:#1e293b
    style L1 fill:#f0fdf4,stroke:#22c55e,stroke-width:2,color:#1e293b
```

Each request is classified into a lane at insertion time based on its
`cmd_flags` (sync, meta, flush, priority), the originating process's I/O
budget balance, and the per-process IO profile (computed from recent budget
and latency signal history).  Per-lane deadline-sorted red-black trees (plus
two FIFO priority queues for the barrier tiers) are the primary scheduling
state.

Dispatch uses a per-hardware-context fast-path: each hardware context
maintains its own dispatch list, starvation counters, and a
high-priority-burst quota counter.  The dispatcher first attempts a
lock-free pop from the per-hctx dispatch list; if empty, it walks the
global lane trees under a short-lived lock to refill the list.  This allows
independent dispatch across multiple hardware queues while preserving the
lane priority order.  Starvation is tracked as round counters per lane and
as burst-quota rounds: when a lane accumulates enough consecutive bypasses
the scheduler force-dispatches from it; when high-priority bursts exceed the
quota threshold, lower lanes are served preemptively.

All per-process scheduling state (budget, containment score, latency
allowance, latency pressure, IO profile) uses atomic operations and is
accessed without the global lock.  The I/O completion path updates these
fields lock-free, making the primary budget refill mechanism (proportional
refill of completed_sectors / 100 on each completion) contention-free.

A 3-mode autotuner (Balanced / Latency / Throughput) runs every second.
It aggregates per-hctx dispatch metrics, computes workload ratios
(latency, rescue, contained, shared), and adjusts batch sizes and starvation
thresholds toward the mode target using step-wise parameter tuning ported
from scx_flow.  No sysfs intervention is needed for common workloads.

> [!TIP]
> For a deeper walkthrough of the lane classification, budget refill mechanics,
> and starvation tracking that flow-iosched adapts, see the
> [scx_flow README](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow).

## Kernel Compatibility

| Kernel range | Notes |
|---|---|
| 7.0.x (CachyOS) | Default target — the source as-is targets this API. |
| 6.18 – 6.19 | Same init_sched API as 7.x — compatible as-is. |
| 6.12 – 6.17 | Older init_sched + depth_updated signatures — apply the existing `patches/0002-linux6.12-flow-iosched-compat.patch` for API compatibility, then build from the v2.0.0 source. |
| 5.18 – 6.11 | `scoped_guard` macros exist (cleanup.h added in 5.18) but the `limit_depth` and `insert_requests` elevator op signatures differ from the 6.12+ API. **Untested** — dedicated compat patches would be needed for this range. |

> [!IMPORTANT]
> The existing `patches/0001` and `patches/0003` are for the v1.1.0 source and are
> **not compatible** with v2.0.0.  For v2.0.0, the scheduler ships as a single
> source file (`block/flow-iosched.c`) — use the standalone module build or
> apply the compat patch for 6.12–6.17 if needed.  New integrated patches for
> v2.0.0 will be published in a future release.

### Building as a Standalone Module (Recommended)

> [!TIP]
> The standalone build does not require patching the kernel — build against
> your running kernel's headers and load at runtime.
>
> Note: Some kernel distributions do not export `block/elevator.h` for
> out-of-tree builds. In that case you can copy the header from the kernel
> source tree or build the scheduler as an integrated module via the
> `patches/` approach below.

```bash
cd block
make -C /lib/modules/$(uname -r)/build M=$(pwd)
sudo insmod flow-iosched.ko
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

To make the selection persist across reboots, add the `echo` line to your
initramfs scripts (e.g. `/etc/initramfs-tools/scripts/init-top/`).

### Integrating Into a Kernel Tree

Place `block/flow-iosched.c` into your kernel source's `block/` directory,
then add the Kconfig and Makefile entries:

```c
// Kconfig (in block/Kconfig.iosched):
config MQ_IOSCHED_FLOW
    tristate "Multi-Lane I/O scheduler (FLOW)"
    default m
    help
      Multi-lane I/O scheduler adapted from scx_flow. Provides five
      priority tiers with deadline-sorted dispatch, per-process budget
      containment, latency credit/debt tracking, and 3-mode autotuning.

// Makefile (in block/Makefile):
obj-$(CONFIG_MQ_IOSCHED_FLOW) += flow-iosched.o
```

For kernels 6.12 – 6.17, also apply
`patches/0002-linux6.12-flow-iosched-compat.patch` for the older
`init_sched` and `depth_updated` API signatures.

Enable `CONFIG_MQ_IOSCHED_FLOW=m` (or `=y`) in your kernel config,
build and install the kernel, then select the scheduler at runtime:

```bash
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

> [!IMPORTANT]
> The `CONFIG_MQ_IOSCHED_DEFAULT_FLOW` Kconfig option lets you make
> flow-iosched the boot-time default, but wiring it into
> `elevator_set_default()` in `block/elevator.c` is kernel-version-specific
> and is **not** handled by the patches.  The standalone module build avoids
> this entirely — select the scheduler at runtime instead.

## Sysfs Tunables

Attributes under `/sys/block/<device>/queue/iosched/`:

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `flow_version` | RO | — | Current scheduler version (2.0.0) |
| `read_priority` | RW | 0 | Read bias vs writes at same deadline (-20 to 19) |
| `sync_budget_sectors` | RW | 2048 | Reserved lane budget per sync dispatch |
| `async_budget_sectors` | RW | 512 | Shared lane budget per async dispatch |
| `batch_max_read` | RW | 16 | Max read requests per batch (adjusted by autotune) |
| `batch_max_write` | RW | 16 | Max write requests per batch |
| `completion_window_ns` | RW | 8000000 | Dispatch batch window (nanoseconds) |
| `starvation_max_reserved` | RW | 5 | Reserved starvation rounds before forced rotation |
| `starvation_max_shared` | RW | 20 | Shared starvation rounds before forced dispatch |
| `starvation_max_contained` | RW | 30 | Contained starvation rounds before rescue |
| `contain_threshold` | RW | 100 | Hog containment activation score |

## Production Ready?

> [!WARNING]
> flow-iosched has not yet undergone extensive real-world testing and should
> not be assumed stable for use on critical systems. If you choose to evaluate
> it, do so on a virtual machine or a spare PC/laptop — not your primary
> workstation. Unforeseen side effects, including data corruption or system
> instability, are possible at this stage.

flow-iosched is adapted from the lane-based design of
[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow),
a sched_ext CPU scheduler developed alongside this project. scx_flow
[v2.2.0](https://github.com/sched-ext/scx/pull/3525) was released on 15 April 2026 and has since accumulated several maintenance releases. scx_flow is used internally at [v.recipes](https://v.recipes) for
production-adjacent workloads and is considered stable for general-purpose
desktop and home-server use.

flow-iosched targets the same level of robustness, but the block layer
demands a higher bar: an I/O scheduler operates on user data directly, and
an undetected bug can cause data corruption or filesystem inconsistency —
not merely degraded performance.

The code has been audited for memory safety, request lifecycle correctness,
lock ordering, integer safety, and error-path robustness.  All internal
functions carry lockdep annotations, and lock ordering (hctx lock → queue
lock) is enforced to prevent deadlock across parallel dispatch contexts.
Version 2.0.0 underwent a structured review that caught a CAS retry-loop
livelock in the atomic helper functions (fixed during review), verified all
per-ICQ fields use correct atomic_t/atomic64_t access with memory barriers,
confirmed lock ordering in the dispatch path, and audited the autotune timer
for proper teardown via del_timer_sync.  All per-process scheduling state is
now accessed without the global fd->lock on the completion path, eliminating
the primary contention point between multi-queue dispatch and completion.

> [!NOTE]
> flow-iosched clears `QUEUE_FLAG_SQ_SCHED` and dispatches independently per
> hardware context.  This avoids the single-queue dispatch bottleneck that
> restricts throughput on high-end NVMe with 16 or more queues — a framework
> constraint that some other blk-mq schedulers (mq-deadline, BFQ) still
> inherit by using single-queue dispatch mode.

## Benchmarks

The [`bench-tests/`](https://github.com/galpt/flow-iosched/tree/main/bench-tests)
directory provides build, test, analysis, install, and cleanup scripts for
flow-iosched kernels.  Because the `elevator.h` header is not exported for
out-of-tree module builds, the scheduler must be integrated into a kernel
tree via the patches and built from source.

The [`benchmark-runs/`](https://github.com/galpt/flow-iosched/tree/main/benchmark-runs) directory contains results and charts from the
v1.1.0-era test environment (described below).  These results were produced
before the budget system was redesigned in v2.0.0 and are **not representative**
of the current scheduler's behaviour.  Version 2.0.0 benchmarks will be
published once collected.

### Results (v1.1.0 — superseded)

All five workloads were run for 30 seconds each per scheduler on two device
types.  These numbers pre-date the v2.0.0 budget redesign; flow-iosched's
performance in these charts was measured with the broken budget system that
effectively degenerated to a single FIFO queue.  The charts are retained for
reference and will be replaced once v2.0.0 benchmarks are available.

### Scripts

#### `build-kernel.sh` — Build a flow-iosched kernel from scratch

This script is self-contained: it downloads the upstream kernel source from
kernel.org, applies the flow-iosched patches, builds the kernel and modules,
installs them to `/boot` with a unique name, and creates a Limine boot entry.

```bash
# Download, build, and install kernel 7.0.5 with flow-iosched
./bench-tests/build-kernel.sh 7.0.5

# Build kernel 6.18 (same API — applies 0001 patch only)
./bench-tests/build-kernel.sh 6.18

# Build kernel 6.12 (different init_sched API — applies 0001 + 0002)
./bench-tests/build-kernel.sh 6.12
```

The script:
1. Downloads the kernel tarball from `cdn.kernel.org` and caches it in
   `./tmp/kernels/` (relative to the script)
2. Extracts the source (skipped if already present)
3. Clones the flow-iosched repo for patches if no local [`patches/`](https://github.com/galpt/flow-iosched/tree/main/patches) directory
   is found — no need to download the repo manually
4. Applies the correct patches for the target kernel version
5. Configures using the running kernel's `.config` as baseline with
   `CONFIG_MQ_IOSCHED_FLOW` enabled
6. Builds `bzImage` and modules
7. Installs to `/boot/vmlinuz-linux-flow-{version}` — never touches the
   default kernel files (e.g. `vmlinuz-linux-cachyos`)
8. Computes BLAKE2b hashes of the installed files and writes a Limine boot
   entry with hash verification and a fallback entry without hashes

**Supported kernel ranges:**

| Range | Notes |
|---|---|
| 7.0.x | Default target — build source as-is |
| 6.18 – 6.19 | Same init_sched API as 7.x — build source as-is |
| 6.12 – 6.17 | Apply `0002` compat patch for older API signature |
| 5.18 – 6.11 | Not supported (different elevator op API) |

> [!TIP]
> Re-running the script after a successful build skips download, extraction,
> and patching — it proceeds straight to configuration, build, and install.
> This makes rebuilds fast after source-code changes during development.

#### `run-benchmarks.sh` — Run fio benchmarks across schedulers

Runs fio with a set of five workloads and compares the running kernel's
available I/O schedulers.  Results are written to `results/summary.csv`.

By default the script uses `null_blk`, a RAM-backed virtual block device.
This is safe for scheduler development — no risk of data corruption —
and produces representative scheduler-to-scheduler comparisons because
the scheduler overhead is measured while physical device latency is
eliminated as a variable.

For real hardware numbers (e.g. to publish IOPS or latency figures),
pass the device path as the first argument.  The script auto-detects
null_blk vs physical and skips the mounted-partition guard for null_blk.

Each workload runs for 30 seconds by default.  This applies to both
null_blk and real hardware.  Override with the `RUNTIME` environment
variable (e.g. `RUNTIME=60` for 60 seconds per test).

The device can also be set via the `DEVICE` environment variable, but
the positional argument is preferred — some sudo configurations strip
environment variables.

> [!NOTE]
> Scheduler ranking (flow vs mq-deadline vs bfq) tends to be consistent
> between null_blk and physical hardware.  If flow is 15% faster on
> null_blk, it will generally be faster on real NVMe too.  The absolute
> numbers differ — null_blk shows scheduler overhead only, real I/O
> includes device latency — but the ratios are usefully predictive.

```bash
# Default: null_blk virtual device, 30s per test (scheduler comparison)
sudo ./bench-tests/run-benchmarks.sh

# Real hardware: dedicated device with no mounted partitions
sudo ./bench-tests/run-benchmarks.sh /dev/nvme1n1

# Longer runtime (both null_blk and real hardware)
RUNTIME=60 sudo ./bench-tests/run-benchmarks.sh /dev/nvme1n1
```

Workloads tested:

| Test | Block size | Queue depth | R/W mix | What it measures |
|---|---|---|---|---|
| Random read | 4 KiB | 32 | 100/0 | Latency lane responsiveness |
| Random write | 4 KiB | 32 | 0/100 | Shared lane throughput |
| Sequential read | 128 KiB | 8 | 100/0 | Bulk throughput (I/O-bound) |
| Sequential write | 128 KiB | 8 | 0/100 | Bulk throughput (I/O-bound) |
| Mixed random | 4 KiB | 8 | 70/30 | Lane interaction under contention |

#### `plot-results.py` — Generate comparison charts

Reads `results/summary.csv` and produces PNG charts in `charts/`:

```bash
python3 bench-tests/plot-results.py
```

Generates four chart files:

| File | Content |
|---|---|
| `charts/iops.png` | Total IOPS per workload, sorted best-to-worst by average IOPS |
| `charts/latency.png` | Read latency per workload, sorted best-to-worst by average read latency |
| `charts/per_workload.png` | Per-workload IOPS sorted best-to-worst per workload |
| `charts/comparison.png` | Consolidated averages sorted best-to-worst per metric |

#### `install-deps.sh` — Install benchmark dependencies

Installs `fio` and `python-matplotlib`, needed by `run-benchmarks.sh` and
`plot-results.py`:

```bash
sudo ./bench-tests/install-deps.sh
```

#### `remove-kernel.sh` — Safely uninstall test kernels

Removes the boot files, Limine entries, and kernel modules for a
flow-iosched test kernel without affecting the default system kernel.

```bash
# Remove a specific kernel
sudo ./bench-tests/remove-kernel.sh 7.0.5

# List all installed flow-iosched kernels
sudo ./bench-tests/remove-kernel.sh --list

# Remove all test kernels (the booted kernel is never touched)
sudo ./bench-tests/remove-kernel.sh --all
```

> [!CAUTION]
> The script will refuse to remove the currently-booted kernel.  It also
> prompts for confirmation before any removal.

### Test Environment

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 7 6800H (8 cores / 16 threads, 3.2 GHz base) |
| Memory | 58 GB DDR5 |
| NVMe drive 1 | 512 GB (NVMe, 4 queues) |
| NVMe drive 2 | Intel SSDPEKNW512GZL (512 GB, 4 queues) |
| Kernel | 7.0.5-2-cachyos, PREEMPT_DYNAMIC |
| Platform | CachyOS Linux |
| Available schedulers | `none`, `mq-deadline`, `kyber`, `bfq`, `adios` |

## Credits

flow-iosched stands on the shoulders of several I/O and CPU scheduling projects
that shaped its design:

- **[ADIOS](https://github.com/firelzrd/adios)** — Adaptive Deadline I/O
  Scheduler.  The batch queue architecture, deadline-based rbtrees, and kernel
  integration pattern are directly adapted from ADIOS v3.2.0.  The per-request
  lifecycle pattern (`prepare_request` / `finish_request`) and the prio_queue +
  dl_tree data structure design follow ADIOS closely.
- **[Kyber](https://github.com/torvalds/linux/blob/master/block/kyber-iosched.c)**
  — The `limit_depth` callback for async queue depth throttling follows the
  approach made popular by the Kyber I/O scheduler.
- **[BFQ](https://github.com/torvalds/linux/blob/master/block/bfq-iosched.c)**
  — The per-process I/O context infrastructure (`.icq_size` / `.icq_align` in
  `struct elevator_type`) used for budget tracking follows the same embedding
  pattern that BFQ pioneered for per-process scheduling state.
- **[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow)**
  — The lane-based priority classification, starvation-aware round counters,
  budget refill mechanics, hog containment model, bounded signal helpers
  (raise/decay geometric), latency credit/debt system, wake-profile-derived
  IO profile, starvation quota mechanism, and the 3-mode autotuner with
  step-wise parameter tuning are all direct adaptations of the scx_flow CPU
  scheduler's design for the block layer.
- **[mq-deadline](https://github.com/torvalds/linux/blob/master/block/mq-deadline.c)**
  — The merge-rbtree helpers (`former_request` / `next_request`) and the
  bio-merge callback pattern follow the conventions established by the
  mq-deadline reference implementation and shared across all in-kernel blk-mq
  schedulers.
- **Linux kernel block layer contributors** — The elevator API, blk-mq
  dispatch framework, and sbitmap infrastructure that flow-iosched builds on.
  These are developed at
  [torvalds/linux/block](https://github.com/torvalds/linux/tree/master/block).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

GNU General Public License v2.0 only.  See [LICENSE](LICENSE).
