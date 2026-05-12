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
| Reserved | Synchronous reads, metadata | configurable (default 250 sectors) | Low-latency path for interactive I/O |
| Latency | Small random I/O | Short batch window | Bounded responsiveness |
| Shared | Async writes, best-effort | Configurable batch limit | Background throughput |
| Contained | Hog-throttled processes | Reduced dispatch rate | Limits I/O-bound interference |

Dispatch priority: Emergency > Reserved > Latency > Shared > Contained.
Starvation counters rotate CPU-intensive I/O flows back into higher lanes so no
lane is abandoned entirely.

## Design

Each request is classified into a lane at insertion time based on its
`cmd_flags` (sync, meta, flush, priority) and the originating process's I/O
budget balance.  Per-lane deadline-sorted red-black trees (plus two FIFO
priority queues for the barrier tiers) feed into batch queues.

Dispatch walks lanes in priority order, pulling requests into batch-sized
groups before submitting to the device.  Starvation is tracked as round
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
| 6.12 – 6.17 | Older init_sched signature — apply `patches/0002-linux6.12-flow-iosched-compat.patch` after 0001. |
| 5.18 – 6.11 | `scoped_guard` macros exist (cleanup.h added in 5.18) but `DEFINE_LOCK_GUARD_1(spinlock_irqsave)` availability is per-release — untested. |

The `patches/` directory follows the approach used by
[ADIOS](https://github.com/firelzrd/adios), shipping separate patches per
kernel cycle.

### Building as a Standalone Module (Recommended)

> [!TIP]
> The standalone build does not require patching the kernel — build against
> your running kernel's headers and load at runtime.

```bash
cd block
make -C /lib/modules/$(uname -r)/build M=$(pwd)
sudo insmod flow-iosched.ko
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

To make the selection persist across reboots, add the `echo` line to your
initramfs scripts (e.g. `/etc/initramfs-tools/scripts/init-top/`).

### Integrating Into a Kernel Tree

1. Apply `patches/0001-linux7.0-flow-iosched-v1.0.0.patch` — creates the
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
| `batch_max_write` | RW | 32 | Max write requests per batch |
| `completion_window_ns` | RW | 8000000 | Dispatch batch window (nanoseconds) |
| `starvation_max_reserved` | RW | 5 | Reserved starvation rounds before forced rotation |
| `starvation_max_shared` | RW | 20 | Shared starvation rounds before forced dispatch |
| `starvation_max_contained` | RW | 30 | Contained starvation rounds before rescue |
| `contain_threshold` | RW | 100 | Hog containment activation score |
| `contain_decay_step` | RW | 8 | Containment score decay per idle interval |

## Production Ready?

For general-purpose desktop and workstation use on SATA SSDs, single-queue
NVMe, and mid-range multi-queue NVMe (up to approximately 8 hardware queues),
yes.

flow-iosched has been reviewed through three rounds of static analysis
covering locking correctness, memory safety, race conditions, kernel API
compatibility, and starvation-edge correctness.  Its core scheduling paths
follow the same bounded design that scx_flow uses for CPU scheduling, adapted
to the block layer through the blk-mq elevator API.

> [!CAUTION]
> On high-end NVMe storage with 16 or more queues, the blk-mq elevator API's
> single-queue dispatch model (`QUEUE_FLAG_SQ_SCHED`) becomes a throughput
> bottleneck.  This is a framework-level constraint shared by **all** blk-mq
> schedulers (mq-deadline, Kyber, BFQ, ADIOS) — not a flow-iosched limitation.

## Benchmarks

Benchmarking flow-iosched against the in-kernel schedulers requires building a
kernel with the scheduler integrated (the `elevator.h` header is not exported
for out-of-tree module builds).  The test setup and scripts are located at
[bench-tests/](https://github.com/galpt/flow-iosched/tree/main/bench-tests).

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

### Workloads

| Test | Block size | Queue depth | R/W mix | What it measures |
|---|---|---|---|---|
| Random read | 4 KiB | 32 | 100/0 | Latency lane responsiveness |
| Random write | 4 KiB | 32 | 0/100 | Shared lane throughput |
| Sequential read | 128 KiB | 8 | 100/0 | Bulk throughput (I/O-bound) |
| Sequential write | 128 KiB | 8 | 0/100 | Bulk throughput (I/O-bound) |
| Mixed random | 4 KiB | 8 | 70/30 | Lane interaction under contention |

> [!NOTE]
> Benchmark results are not yet available.  The workloads above are the planned
> test suite.  Results will be published here once the kernel integration build
> is complete and runs have been collected.  See
> [bench-tests/](https://github.com/galpt/flow-iosched/tree/main/bench-tests)
> for the build scripts and benchmark runner.

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
