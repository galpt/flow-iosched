# flow-iosched

Multi-lane I/O scheduler for the Linux block layer, adapted from the lane-based
budget and classification design of the
[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow)
CPU scheduler.

> [!NOTE]
> flow-iosched targets the same audience as its CPU-side inspiration: general-purpose
> desktop and workstation machines where responsiveness and throughput both matter.

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
%%{init: {'theme': 'base', 'themeVariables': {'background': 'transparent'}}}%%
flowchart TD
    subgraph Pipeline["Pipeline"]
        direction LR
        A["1. I/O Request&lt;br&gt;&lt;small&gt;Bio arrives from blk-mq&lt;br&gt;flow_prepare_request allocs&lt;br&gt;flow_rq_data from mempool&lt;/small&gt;"]
        B["2. Lane Classification&lt;br&gt;&lt;small&gt;flow_assign_lane() inspects:&lt;br&gt;cmd_flags, is_write, budget, AT_HEAD&lt;br&gt;→ assigns lane 1–5 + deadline&lt;/small&gt;"]
        C["Emergency&lt;br&gt;&lt;small&gt;AT_HEAD bypass&lt;br&gt;FIFO, prio_queue[0]&lt;/small&gt;"]
        D["Reserved&lt;br&gt;&lt;small&gt;Sync reads + metadata/prio&lt;br&gt;2048 sector budget&lt;/small&gt;"]
        E["Latency&lt;br&gt;&lt;small&gt;REQ_SYNC writes, ≤ 4 KB&lt;br&gt;2 ms deadline offset&lt;/small&gt;"]
        F["Shared&lt;br&gt;&lt;small&gt;Async writes, best-effort&lt;br&gt;512 sector budget&lt;/small&gt;"]
        G["Contained&lt;br&gt;&lt;small&gt;Hog-throttled if score ≥ 100&lt;br&gt;score −8 per idle tick&lt;/small&gt;"]
        H["4. Per-hctx Dispatch&lt;br&gt;&lt;small&gt;Phase 1 (fast): pop from list&lt;br&gt;Phase 2 (slow): refill from rbtrees&lt;br&gt;QUEUE_FLAG_SQ_SCHED cleared&lt;/small&gt;"]
        I("5. Device&lt;br&gt;&lt;small&gt;NVMe / SATA&lt;/small&gt;")

        A -->|main flow| B
        B -->|lane 1| C
        B -->|lane 2| D
        B -->|lane 3| E
        B -->|lane 4| F
        B -->|lane 5| G
        C -->|dispatch| H
        D -->|dispatch| H
        E -->|dispatch| H
        F -->|dispatch| H
        G -->|dispatch| H
        H -->|I/O completion| I
    end

    subgraph Support["Supporting Systems"]
        direction LR
        J["Budget &amp; Containment&lt;br&gt;&lt;small&gt;flow_icq_data via icq_size&lt;br&gt;1. refill if idle &gt; 100 ms&lt;br&gt;2. deduct sectors&lt;br&gt;3. if budget &lt; 0 → score +10&lt;br&gt;4. if score ≥ 100 → demote&lt;br&gt;5. idle refill → score −= 8&lt;/small&gt;"]
        K["Starvation Tracking&lt;br&gt;&lt;small&gt;per-hctx starvation_rounds[5]&lt;br&gt;round++ on each bypass&lt;br&gt;rounds ≥ max → force-dispatch&lt;br&gt;defaults: 5, 20, 30&lt;/small&gt;"]
        L["ICQ Lifecycle&lt;br&gt;&lt;small&gt;flow_init_icq: zero-init data&lt;br&gt;flow_exit_icq: memset to zero&lt;br&gt;prevents use-after-free&lt;br&gt;NULL-guarded at all sites&lt;/small&gt;"]
    end

    B -.->|budget check| J
    J -.->|demote| G
    C -.->|bypass tracking| K
    D -.->|bypass tracking| K
    E -.->|bypass tracking| K
    F -.->|bypass tracking| K
    G -.->|bypass tracking| K
    K -.->|force-dispatch| H
    L -.->|per-process state| J

    style A fill:#eef2ff,stroke:#6366f1,stroke-width:2
    style B fill:#fff,stroke:#94a3b8,stroke-width:2
    style C fill:#fff,stroke:#dc2626,stroke-width:2
    style D fill:#fff,stroke:#2563eb,stroke-width:2
    style E fill:#fff,stroke:#16a34a,stroke-width:2
    style F fill:#fff,stroke:#d97706,stroke-width:2
    style G fill:#fff,stroke:#9333ea,stroke-width:2
    style H fill:#f0f9ff,stroke:#0ea5e9,stroke-width:2
    style I fill:#fef2f2,stroke:#ef4444,stroke-width:2
    style J fill:#faf5ff,stroke:#a855f7,stroke-width:2
    style K fill:#fff7ed,stroke:#f59e0b,stroke-width:2
    style L fill:#f0fdf4,stroke:#22c55e,stroke-width:2
    style Pipeline fill:#f8fafc,stroke:#e2e8f0,stroke-dasharray:5
    style Support fill:#f8fafc,stroke:#e2e8f0,stroke-dasharray:5
```

Each request is classified into a lane at insertion time based on its
`cmd_flags` (sync, meta, flush, priority) and the originating process's I/O
budget balance.  Per-lane deadline-sorted red-black trees (plus two FIFO
priority queues for the barrier tiers) are the primary scheduling state.

Dispatch uses a per-hardware-context fast-path: each hardware context
maintains its own dispatch list and starvation counters.  The dispatcher
first attempts a lock-free pop from the per-hctx dispatch list; if empty,
it walks the global lane trees under a short-lived lock to refill the list.
This allows independent dispatch across multiple hardware queues while
preserving the lane priority order.  Starvation is tracked as round
counters per lane — when a lane accumulates enough consecutive bypasses the
scheduler force-dispatches from it, ensuring fairness without wall-clock
timers.

Processes that exceed their I/O budget accumulate a containment score; once
the score passes the containment threshold their I/O is demoted to the
contained lane until the score decays below the threshold again.

> [!TIP]
> For a deeper walkthrough of the lane classification, budget refill mechanics,
> and starvation tracking that flow-iosched adapts, see the
> [scx_flow README](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow).

## Kernel Compatibility

| Kernel range | Notes |
|---|---|
| 7.0.x (CachyOS) | Default target — use source as-is.  (CachyOS ships `MQ_IOSCHED_ADIOS` which uses the same elevator API.) |
| 6.18 – 6.19 | Same init_sched API as 7.x — use source as-is. |
| 6.12 – 6.17 | Older init_sched + depth_updated signatures — apply `patches/0002-linux6.12-flow-iosched-compat.patch` after applying `patches/0001-linux7.0-flow-iosched-v1.1.0.patch`. |
| 5.18 – 6.11 | `scoped_guard` macros exist (cleanup.h added in 5.18) but the `limit_depth` and `insert_requests` elevator op signatures differ from the 6.12+ API. **Untested** — a dedicated compat patch would be needed for this range. |

The `patches/` directory follows the approach used by
[ADIOS](https://github.com/firelzrd/adios), shipping separate patches per
kernel cycle.

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

1. Apply `patches/0001-linux7.0-flow-iosched-v1.1.0.patch` — creates the
   scheduler source, Kconfig entry, and Makefile target.
2. For kernels 6.12 – 6.17, also apply
   `patches/0002-linux6.12-flow-iosched-compat.patch`.
3. Enable `CONFIG_MQ_IOSCHED_FLOW=m` (or `=y`) in your kernel config.
4. Build and install the kernel, then select the scheduler at runtime:

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
| `flow_version` | RO | — | Current scheduler version |
| `read_priority` | RW | 0 | Read bias vs writes at same deadline (-20 to 19) |
| `sync_budget_sectors` | RW | 2048 | Reserved lane budget per sync dispatch |
| `async_budget_sectors` | RW | 512 | Shared lane budget per async dispatch |
| `batch_max_read` | RW | 16 | Max read requests per batch |
| `batch_max_write` | RW | 16 | Max write requests per batch |
| `completion_window_ns` | RW | 8000000 | Dispatch batch window (nanoseconds) |
| `starvation_max_reserved` | RW | 5 | Reserved starvation rounds before forced rotation |
| `starvation_max_shared` | RW | 20 | Shared starvation rounds before forced dispatch |
| `starvation_max_contained` | RW | 30 | Contained starvation rounds before rescue |
| `contain_threshold` | RW | 100 | Hog containment activation score |
| `contain_decay_step` | RW | 8 | Containment score decay per idle interval |

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
[v2.2.0](https://github.com/sched-ext/scx/commit/00003869) was released in
April 2026 and has since accumulated several maintenance releases (current:
v2.2.5). It is used internally at [v.recipes](https://v.recipes) for
production-adjacent workloads and is considered stable for general-purpose
desktop and home-server use.

flow-iosched targets the same level of robustness, but the block layer
demands a higher bar: an I/O scheduler operates on user data directly, and
an undetected bug can cause data corruption or filesystem inconsistency —
not merely degraded performance. The code has been audited for counter
edge cases (starvation rounds, containment scoring, budget arithmetic),
memory allocation paths, and rbtree lifecycle correctness.  All internal
functions carry lockdep annotations, and lock ordering (hctx lock → queue
lock) is enforced to prevent deadlock across parallel dispatch contexts.

This audit discovered and fixed a scheduling bypass bug where every
non-emergency request was incorrectly added to a FIFO tracking list
alongside its lane rbtree, causing dispatch to bypass the lane priority
system entirely.  The presence of a real, testable logic error in the
current code underscores why the scheduler should be treated as
experimental until it has accumulated more field testing across varied
hardware and workloads.

> [!NOTE]
> flow-iosched clears `QUEUE_FLAG_SQ_SCHED` and dispatches independently per
> hardware context.  This avoids the single-queue dispatch bottleneck that
> restricts throughput on high-end NVMe with 16 or more queues — a framework
> constraint that some other blk-mq schedulers (mq-deadline, BFQ) still
> inherit by using single-queue dispatch mode.

## Benchmarks

The [`bench-tests/`](https://github.com/galpt/flow-iosched/tree/main/bench-tests)
directory provides four scripts for building, testing, analysing, and
cleaning up flow-iosched kernels.  Because the `elevator.h` header is not
exported for out-of-tree module builds, the scheduler must be integrated
into a kernel tree via the patches and built from source.

> [!NOTE]
> Benchmark results are not yet available for publication.  The workloads
> described below are the planned test suite.  Results will be added here
> once the integration build is complete and runs have been collected.

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
3. Clones the flow-iosched repo for patches if no local `patches/` directory
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

| Range | Patches applied | Notes |
|---|---|---|
| 7.0.x | `0001` only | Default target |
| 6.18 – 6.19 | `0001` only | Same init_sched API as 7.x |
| 6.12 – 6.17 | `0001` + `0002` | Older init_sched signature |
| 5.18 – 6.11 | — | Not supported (different elevator op API) |

> [!TIP]
> Re-running the script after a successful build skips download, extraction,
> and patching — it proceeds straight to configuration, build, and install.
> This makes rebuilds fast after source-code changes during development.

#### `run-benchmarks.sh` — Run fio benchmarks across schedulers

Runs fio with a set of five workloads and compares the running kernel's
available I/O schedulers.  Results are written to `results/summary.csv`.

```bash
# Run all benchmarks (requires root for scheduler switching)
sudo ./bench-tests/run-benchmarks.sh

# Specify a different device and runtime
DEVICE=/dev/nvme1n1 RUNTIME=60 sudo ./bench-tests/run-benchmarks.sh
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
| `charts/iops.png` | Total IOPS per workload, grouped by scheduler |
| `charts/latency.png` | Read latency per workload, grouped by scheduler |
| `charts/per_workload.png` | Per-workload IOPS as horizontal bars |
| `charts/comparison.png` | Consolidated averages sorted best-to-worst per metric |

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
  budget refill mechanics, and hog containment model are direct adaptations of
  the scx_flow CPU scheduler's design for the block layer.
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
