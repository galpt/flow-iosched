# flow-iosched

Multi-lane I/O scheduler for the Linux block layer.

flow-iosched targets general-purpose desktop and workstation machines where
responsiveness and throughput both matter.

## Overview

| Lane | Target I/O | Deadline | Behaviour |
|------|------------|----------|-----------|
| Emergency | `BLK_MQ_INSERT_AT_HEAD` | Immediate | Bypasses all scheduling |
| Read | Synchronous reads, metadata, small writes | start_time_ns (FIFO) | Low-latency path for interactive I/O |
| Write | Async writes, best-effort | start_time_ns + 2000ms | Background throughput |

Dispatch priority: Emergency > Read > Write.
Anti-starvation is via a generalised N-lane starvation-bound framework:
per-lane `bypass_count[L]` tracks consecutive dispatch cycles bypassing
lane L; when it reaches `starvation_max[L]`, the lane is force-serviced
and all bypass counters reset.  This reduces to mq-deadline's proven
writes_starved design when N=2, and extends the same formal guarantee
to 3 lanes.

## Design

Read the diagram like this:

- start at the `Start` circle
- follow arrows from top to bottom
- diamond shapes are lane classification decisions — the arrow label tells
  you which requests go where
- solid arrows show the main data flow from request to device
- dotted arrows show how the starvation-bound counters influence dispatch
- the emergency lane is drained before any other lane on every dispatch cycle
- the Read lane is dispatched in batches (up to `batch_max_read`)
- the Write lane is dispatched when the Read lane is empty or when its
  starvation counter triggers a force-dispatch

```mermaid
flowchart TB
    Start((Start)) --> A1["1. I/O Request

A bio arrives from the blk-mq layer.
flow_prepare_request() stores no
scheduler metadata (priv[0] = NULL);
per-request state (lane, rbtree node,
FIFO entry) is set during insertion
using embedded request fields."]

    A1 --> B1["2. Lane Classification

flow_assign_lane() inspects:
cmd_flags, is_write, size,
insert_flags. Returns a lane
(0 = Emergency, 1 = Read,
2 = Write)."]

    B1 --> N3{"3. Which Lane?"}

    D1["Read

Sync reads, metadata,
priority, small writes.
Per-hctx FIFO + rbtree.
Async depth: nr_req / 3."]

    K1["Starvation-Bound Counters

bypass_count[Read/Write]
reset on force-dispatch.
Generalised mq-deadline
writes_starved for N lanes."]

    C1["Emergency

BLK_MQ_INSERT_AT_HEAD.
prio_queue[0] — immediate,
unconditional, no FIFO."]

    F1["Write

Async writes, best-effort.
2000 ms deadline window.
Per-hctx FIFO + rbtree.
Dispatched when Read empty
or starvation forces it."]

    N3 -- "AT_HEAD?\n→ Emergency" --> C1
    N3 -- "sync read, meta,\nprio, or ≤ 4 KB?\n→ Read" --> D1
    N3 -- "async write or\nbest-effort?\n→ Write" --> F1

    D1 -.->|"Read→bc[W]++"| K1
    F1 -.->|"Write→bc[R]++"| K1

    C1 -->|"drain prio_queue[0]"| H1["4. Per-hctx Dispatch

flow_dispatch_request(hctx):
1. Pop prio queue (fd->lock)
2. Select lane via starvation
   + batch (khd->lock)
3. Pop one request from
   lane FIFO, remove from rbtree
Two-phase lock.  SQ_SCHED cleared."]

    D1 -->|"batch ≤ bmax_r"| H1
    F1 -->|"batch ≤ bmax_w\nor starved"| H1

    H1 -->|"submit to device"| I1["5. Device

NVMe, SATA, virtual.
Multi-hctx.
Each dispatches
independently."]

    K1 -.->|"bc[L]≥max?\nforce L, reset"| H1

    style Start fill:#1e293b,stroke:#0ea5e9,stroke-width:2,color:#fff
    style A1 fill:#eef2ff,stroke:#6366f1,stroke-width:2,color:#1e293b
    style B1 fill:#fff,stroke:#94a3b8,stroke-width:2,color:#1e293b
    style N3 fill:#fff,stroke:#64748b,stroke-width:2,color:#1e293b
    style C1 fill:#fff,stroke:#dc2626,stroke-width:2,color:#1e293b
    style D1 fill:#fff,stroke:#2563eb,stroke-width:2,color:#1e293b
    style F1 fill:#fff,stroke:#16a34a,stroke-width:2,color:#1e293b
    style H1 fill:#f0f9ff,stroke:#0ea5e9,stroke-width:2,color:#1e293b
    style I1 fill:#fef2f2,stroke:#ef4444,stroke-width:2,color:#1e293b
    style K1 fill:#fff7ed,stroke:#f59e0b,stroke-width:2,color:#1e293b
```

The diagram above covers the main I/O path.  A few implementation details
that do not fit in the flowchart:

- **Two FIFO priority queues** (`prio_queue[0]` and `prio_queue[1]`) back
  the Emergency lane and the barrier/flush path.  These are drained before
  the per-hctx FIFO lists on every dispatch cycle.
- **Each hardware context (hctx) has its own set of per-lane FIFO lists**
  and sector-sorted rbtrees, each protected by its own spinlock (`khd->lock`).
  This eliminates the single-lock contention that would otherwise arise on
  multi-queue NVMe devices (up to 16+ independent dispatch streams).
- **Zero per-request dynamic allocations.**  The lane identifier is stored as
  a tagged pointer in `rq->elv.priv[0]`; the deadline lives in `rq->fifo_time`;
  rbtree linkage uses the embedded `rq->rb_node`; FIFO list membership uses
  `rq->queuelist`.  This matches mq-deadline's allocation discipline.
- **Starvation-bound dispatch** checks lanes from lowest priority upward
  (Write → Read).  If `bypass_count[lane] >= starvation_max[lane]` and the
  lane has pending requests, it is force-serviced and all bypass counters
  reset.  Otherwise the highest-priority non-empty lane dispatches within
  its batch limit (`batch_max_read` / `batch_max_write`).
- **`QUEUE_FLAG_SQ_SCHED` is cleared**, so each hardware context dispatches
  independently — no single-queue bottleneck on multi-queue NVMe devices.
- **No autotune timer** — all scheduling parameters are static (set at
  module load time, tunable via sysfs), matching mq-deadline's operational
  model.
- **No per-process scheduling state** — the ICQ lifecycle hooks and
  `completed_request` callback have been removed.  Fairness is determined
  entirely by dispatch ordering with starvation bounds.
- **Completion-triggered re-dispatch** — when a request completes and work
  remains pending, the hctx restart flag is marked (lighter version of BFQ's
  pipeline-refill pattern).

## Kernel Compatibility

| Kernel range | Notes |
|---|---|
| 7.0.x (CachyOS) | Default target — the v4.0 source targets this API. |
| 6.18 – 6.19 | Same init_sched API as 7.x — compatible as-is. |
| 6.12 – 6.17 | Older init_sched + depth_updated signatures — a compat patch for v4.0 has not yet been published for this range. |
| 5.18 – 6.11 | `scoped_guard` macros exist (cleanup.h added in 5.18) but the `limit_depth` and `insert_requests` elevator op signatures differ from the 6.12+ API. **Untested** — dedicated compat patches would be needed for this range. |

> [!IMPORTANT]
> The `patches/` directory contains generated patches for in-tree
> integration.  After any source change, run
> `./bench-tests/generate-patches.py` to keep them in sync.
> The preferred build method is the standalone module build (see
> below), which does not require patching the kernel tree.

### Standalone Module Build (Recommended)

The easiest way to try flow-iosched is the [`install-flow-ioshed.sh`](#install-flow-ioschedsh--build-and-install-as-a-standalone-module) script, which handles building, installation, and persistence automatically:

```bash
sudo ./bench-tests/install-flow-ioshed.sh
```

Alternatively, build manually against your running kernel:

```bash
cd block
make -C /lib/modules/$(uname -r)/build M=$(pwd) \
    CONFIG_MQ_IOSCHED_FLOW=m CC=clang LD=ld.lld \
    KCFLAGS="-I/path/to/kernel-source/block" modules
sudo insmod flow-iosched.ko
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

> [!TIP]
> The standalone build does not require patching the kernel — build against
> your running kernel's headers and load at runtime.
>
> Note: Some kernel distributions do not export `block/elevator.h` for
> out-of-tree builds. The install script handles this automatically by
> pointing the compiler at a matching kernel source tree.  If building
> manually, you will need a kernel source tree available for the `-I` flag.

### Integrating Into a Kernel Tree

Place `block/flow-iosched.c` into your kernel source's `block/` directory,
then add the Kconfig and Makefile entries:

```c
// Kconfig (in block/Kconfig.iosched):
config MQ_IOSCHED_FLOW
    tristate "Multi-Lane I/O scheduler (FLOW)"
    default m
    help
      Multi-lane I/O scheduler with three priority tiers (Emergency,
      Read, Write), per-hw-context FIFO dispatch, and starvation-bound
      anti-starvation (generalised mq-deadline for N lanes).

// Makefile (in block/Makefile):
obj-$(CONFIG_MQ_IOSCHED_FLOW) += flow-iosched.o
```

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
| `flow_version` | RO | — | Current scheduler version (4.0) |
| `read_priority` | RW | 0 | Read bias vs writes at same deadline (-20 to 19) |
| `batch_max_read` | RW | 16 | Max read requests per dispatch batch |
| `batch_max_write` | RW | 16 | Max write requests per dispatch batch |
| `starvation_max_read` | RW | 5 | Read max-bypass before force-dispatch |
| `starvation_max_write` | RW | 20 | Write max-bypass before force-dispatch |

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
demands a higher bar: an I/O scheduler operates on user data directly.
An undetected bug can cause data corruption or filesystem inconsistency —
not merely degraded performance.

> [!NOTE]
> flow-iosched clears `QUEUE_FLAG_SQ_SCHED` and dispatches independently per
> hardware context.  This avoids the single-queue dispatch bottleneck that
> restricts throughput on high-end NVMe with 16 or more queues — a framework
> constraint that some other blk-mq schedulers (mq-deadline, BFQ) still
> inherit by using single-queue dispatch mode.

## Benchmarks

The [`bench-tests/`](https://github.com/galpt/flow-iosched/tree/main/bench-tests)
directory provides build, test, analysis, install, and cleanup scripts for
flow-iosched.  The standalone [`install-flow-iosched.sh`](#install-flow-ioschedsh--build-and-install-as-a-standalone-module)
script builds and loads the module against your running kernel without
patching the kernel tree.

The [`benchmark-runs/`](https://github.com/galpt/flow-iosched/tree/main/benchmark-runs) directory contains results and charts from the test
environment described below.

### Results

All five workloads were run for 30 seconds each per scheduler on two device
types.  The charts below show each scheduler's throughput and latency.

#### null_blk (synthetic RAM device)

null_blk is a kernel virtual block device with near-zero I/O latency (memory
copy only).  Results measure the scheduler's CPU overhead and dispatch logic
without the confounding factor of physical device latency.  The absolute IOPS
numbers are not representative of real hardware, but the comparisons between
schedulers are useful: a scheduler that is slower on null_blk is doing more
work per I/O — and that overhead matters on real hardware too.

| Chart | What to look for |
|-------|-------------------|
| ![IOPS](benchmark-runs/null_blk/charts/iops.png) | **Total IOPS** — higher is better.  Writes remain slower than reads on null_blk, which is expected: writes use a 2000 ms deadline window (Write lane) while reads use the FIFO Read lane.  BFQ's per-process accounting keeps it at the bottom on this zero-latency device — a reminder that scheduling always costs something. |
| ![Latency](benchmark-runs/null_blk/charts/latency.png) | **Read latency** — lower is better.  flow-iosched read latency is competitive with kyber and mq-deadline across all read-bearing workloads.  Write-only workloads naturally have no read latency bars. |
| ![Per-workload IOPS](benchmark-runs/null_blk/charts/per_workload.png) | **Per-workload breakdown** — every workload sorted best-to-worst for that specific workload.  flow-iosched sits mid-pack on reads; writes trail the leaders, which is the honest picture of where the scheduler stands today on synthetic zero-latency media. |
| ![Consolidated averages](benchmark-runs/null_blk/charts/comparison.png) | **Averages across all workloads** — one glance at the spread.  flow-iosched lands mid-pack on IOPS and read latency, with write latency still the area needing most improvement.  The v4.0 re-architecture (per-hctx locks, zero allocations) may change this picture — benchmarks have not yet been re-run. |

> [!NOTE]
> **Why are writes slower?**  flow-iosched classifies writes as background
> (Write lane) by default.  They are dispatched only after the Read lane
> is drained or the starvation-bound counter forces them.  On null_blk
> where actual I/O takes zero time, this scheduling overhead is the dominant
> factor.  On real hardware it largely disappears behind device latency —
> see the physical device charts below.

#### Physical device (NVMe, `/dev/nvme1n1p1`)

The same benchmarks run on a real NVMe partition (secondary NVMe drive).
These numbers reflect actual device I/O, including NVMe controller latency
and PCIe transfer overhead.

| Chart | What to look for |
|-------|-------------------|
| ![IOPS](benchmark-runs/physical_device/charts/iops.png) | **Total IOPS** — the "none" scheduler leads on random reads (this drive reaches ~390k IOPS with zero scheduling overhead), but all full schedulers cluster in the same band.  flow-iosched is competitive with mq-deadline on sequential and mixed workloads, and leads on random writes.  On random reads the gap is larger, but the headline remains: **flow-iosched's scheduling overhead does not cost you throughput on real storage under realistic mixed workloads.** |
| ![Latency](benchmark-runs/physical_device/charts/latency.png) | **Read latency** — the NVMe controller's own latency dominates.  All schedulers cluster in the same band; flow-iosched is competitive with every other scheduler. |
| ![Per-workload IOPS](benchmark-runs/physical_device/charts/per_workload.png) | **Per-workload breakdown** — all full schedulers produce nearly identical bar heights.  The "none" scheduler shows the drive's raw ceiling on random reads, but the takeaway for real-world use is that every full scheduler converges to the same band — the choice between them does not materially change throughput. |
| ![Consolidated averages](benchmark-runs/physical_device/charts/comparison.png) | **Averages across all workloads** — the spread visible on null_blk has collapsed.  Read IOPS, write IOPS, and latencies are all within a narrow band across schedulers.  This is the most important chart in this section: it shows that **flow-iosched's lane-based scheduling does not penalise you on real hardware.** |

> [!NOTE]
> These runs use the flow-iosched module built against and loaded on
> the stock CachyOS kernel (`7.0.8-1-cachyos`) via the standalone module
> install script (`install-flow-iosched.sh`).  The `null_blk` charts were
> measured first, then the physical device — both on the same boot session
> to minimise variation.

#### What this means for you

If you're considering flow-iosched for your desktop or workstation, here is
the honest takeaway:

1. **On real NVMe hardware, all full schedulers converge.**  flow-iosched,
   kyber, mq-deadline, and adios all deliver comparable IOPS on mixed and
   sequential workloads, and on random writes flow-iosched leads.  On
   random reads the gap to mq-deadline is wider (this drive's controller
   favours schedulers with simpler submission ordering), but even there
   the difference is invisible in practice — the scheduler's job is to
   decide which I/O gets priority under contention, not to maximise
   single-workload benchmarks.

2. **flow-iosched prioritises reads over writes.**  That is by design: the
   lane system puts synchronous reads (Read lane) ahead of async writes
   (Write lane).  On a busy system where a background write flood would
   otherwise stall interactive reads, this differentiation provides
   value — at the cost of write throughput under synthetic write-only
   benchmarks.

3. **Starvation bounds are provably correct.**  The generalised N-lane
   framework guarantees each lane is served at most `starvation_max[L]`
   dispatch cycles apart.  No tuning needed for typical desktop use.
   The `starvation_max_read` and `starvation_max_write` sysfs parameters
   let you adjust the trade-off if desired.

4. **Write performance on null_blk looks worse than it is in practice.**
   null_blk has zero I/O latency, so scheduler overhead is the only
   factor.  On a real drive where I/O takes milliseconds, that overhead
   disappears.  The physical device charts confirm this.

5. **BFQ is not a fair comparison on null_blk.**  BFQ's per-process
   scheduling is inherently more expensive, and null_blk exposes that
   cost dramatically.  On real hardware the gap narrows, but BFQ remains
   the heaviest scheduler.  flow-iosched is designed to be lighter than
   BFQ while providing more differentiation than mq-deadline.

### Scripts

#### `build-kernel.sh` — Build a flow-iosched kernel from scratch

This script is self-contained: it downloads the upstream kernel source from
kernel.org, applies the flow-iosched patches, builds the kernel and modules,
installs them to `/boot` with a unique name, and creates a Limine boot entry.

```bash
# Download, build, and install kernel 7.0.8 with flow-iosched
./bench-tests/build-kernel.sh 7.0.8

# Build kernel 6.18 (same API — applies 0001 patch only)
./bench-tests/build-kernel.sh 6.18

# Build kernel 6.12 (different init_sched API — applies 0001 + 0002)
./bench-tests/build-kernel.sh 6.12
```

The script:
1. Downloads the kernel tarball from `cdn.kernel.org` and caches it in
   `./tmp/kernels/` (relative to the script)
2. Extracts the source (skipped if already present)
3. Clones the flow-iosched repo for patches if no local [`patches/`](https://github.com/galpt/flow-iosched/tree/v4.0/patches) directory
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
> Scheduler ranking on null_blk does not always predict real-hardware
> ranking.  null_blk shows scheduler overhead in isolation: a scheduler
> that is slower on null_blk does more work per I/O.  On a real device
> where I/O latency dominates, that overhead often disappears.  The
> physical device charts tell the honest story.

```bash
# Default: null_blk virtual device, 30s per test (scheduler comparison)
sudo ./bench-tests/run-benchmarks.sh

# Real hardware: dedicated device or partition with no mounted filesystems
sudo ./bench-tests/run-benchmarks.sh /dev/nvme1n1p1

# Longer runtime (both null_blk and real hardware)
RUNTIME=60 sudo ./bench-tests/run-benchmarks.sh /dev/nvme1n1p1
```

Workloads tested:

| Test | Block size | Queue depth | R/W mix | What it measures |
|------|------------|-------------|---------|-------------------|
| Random read | 4 KiB | 32 | 100/0 | Read lane responsiveness |
| Random write | 4 KiB | 32 | 0/100 | Write lane throughput |
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
sudo ./bench-tests/remove-kernel.sh 7.0.8

# List all installed flow-iosched kernels
sudo ./bench-tests/remove-kernel.sh --list

# Remove all test kernels (the booted kernel is never touched)
sudo ./bench-tests/remove-kernel.sh --all
```

> [!CAUTION]
> The script will refuse to remove the currently-booted kernel.  It also
> prompts for confirmation before any removal.

#### `install-flow-ioshed.sh` — Build and install as a standalone module

No full kernel rebuild is needed.  This script builds `flow-iosched.ko`
against your running kernel's headers, loads it, and makes it the default
I/O scheduler permanently (across reboots) via a systemd oneshot service
and modules-load.d config.  This is the recommended way to try flow-iosched
on your existing system.

```bash
# One-time: build, install, and enable
sudo ./bench-tests/install-flow-iosched.sh

# Check status
sudo ./bench-tests/install-flow-iosched.sh --status

# Remove completely
sudo ./bench-tests/install-flow-iosched.sh --remove
```

During the first run, the script will offer to download a matching kernel
source from `cdn.kernel.org` if the necessary block-layer headers are not
found locally — this is a one-time download (~210 MB).  The script detects
the compiler used by your kernel (gcc or clang) and uses the corresponding
toolchain automatically.

What the script does:

1. **Detects your toolchain** — clang + lld for CachyOS / Arch, gcc + ld
   for other distributions
2. **Finds or downloads kernel source** — looks in `/lib/modules/.../build/`,
   your local kernel source cache, and `/usr/src/`; falls back to downloading
   from `cdn.kernel.org`
3. **Builds** `flow-iosched.ko` against the running kernel
4. **Installs** to `/lib/modules/$(uname -r)/extra/` and runs `depmod -a`
5. **Creates a systemd oneshot service** (`flow-iosched-scheduler@.service`)
   that sets flow-iosched on each eligible block device after `local-fs.target`,
   plus a `modules-load.d` config to load the module at boot
6. **Loads** the module immediately and activates it on eligible devices
   (no reboot required)
7. **`--remove`** undoes all of the above: restores the previous scheduler,
   unloads the module, removes the systemd service and `.ko` file

> [!NOTE]
> The systemd service selects flow-iosched for all eligible block devices at
> boot.  You can override per device at any time:
> ```bash
> echo mq-deadline | sudo tee /sys/block/<device>/queue/scheduler
> ```

### Test Environment

| Component | Detail |
|-----------|--------|
| CPU | AMD Ryzen 7 6800H (8 cores / 16 threads, 3.2 GHz base) |
| Memory | 58 GB DDR5 |
| NVMe drive 1 (boot/system) | INTEL SSDPEKNW512GZL (512 GB, 4 queues) |
| NVMe drive 2 (benchmark target) | 512 GB NVMe (4 queues) |
| Kernel | 7.0.8-1-cachyos, PREEMPT_DYNAMIC |
| Platform | CachyOS Linux |
| Available schedulers | `none`, `mq-deadline`, `kyber`, `bfq`, `adios`, `flow-iosched` |

## Credits

flow-iosched stands on the shoulders of several I/O and CPU scheduling projects
that shaped its design.  The architectural patterns listed below were studied,
understood, and independently re-implemented for flow's three-lane architecture.
No code was copied from any of these projects.

- **[mq-deadline](https://github.com/torvalds/linux/blob/master/block/mq-deadline.c)**
  — The starvation-bound framework is a generalisation of mq-deadline's
  `writes_starved` to N lanes.  The use of embedded request fields
  (`rq->elv.priv[0]` for scheduler metadata, `rq->rb_node` for rbtree
  linkage, `rq->queuelist` for FIFO lists) follows mq-deadline's
  zero-allocation prepare_request discipline.  The bio-merge and front-merge
  callbacks (`bio_merge`, `request_merge`, `request_merged`,
  `requests_merged`) follow the same contracts as mq-deadline's merge
  infrastructure.
- **[Kyber](https://github.com/torvalds/linux/blob/master/block/kyber-iosched.c)**
  — The per-hw-context state design with independent per-hctx locking is
  adapted from kyber's scalability model.  The lock-free `has_work`
  implementation (using `list_empty_careful`) follows kyber's approach.
  The `limit_depth` callback for async queue depth throttling follows the
  convention kyber made popular.
- **[BFQ](https://github.com/torvalds/linux/blob/master/block/bfq-iosched.c)**
  — The completion-triggered re-dispatch in `flow_finish_request` (marking
  the hctx for restart when pending work remains) is a lighter version of
  BFQ's pipeline-refill pattern.
- **[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow)**
  — The 3-lane design was originally inspired by the scx_flow CPU scheduler.
  flow-iosched now shares more structural DNA with mq-deadline than scx_flow,
  but the lane concept originates here.
- **Linux kernel block layer contributors** — The elevator API, blk-mq
  dispatch framework, and sbitmap infrastructure that flow-iosched builds on.
  These are developed at
  [torvalds/linux/block](https://github.com/torvalds/linux/tree/master/block).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

GNU General Public License v2.0 only.  See [LICENSE](LICENSE).
