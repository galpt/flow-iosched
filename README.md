# flow-iosched

Multi-lane I/O scheduler for the Linux block layer, adapted from the lane-based
budget and classification design of the
[scx_flow](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow)
CPU scheduler.

## Overview

flow-iosched classifies I/O requests into bounded priority lanes and dispatches
them through a starvation-aware round-counter system.  The same design patterns
that keep interactive wakeups responsive in scx_flow — bounded service lanes,
budget tracking, containment for hogs, and O(1) starvation counters — are
mapped to I/O request handling.

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

## Kernel Compatibility

flow-iosched targets **Linux 6.12 and later** (including 7.x).  The current
source uses the kernel 7.x `init_sched` callback signature which passes a
pre-allocated `elevator_queue *`.  The table below covers the tested range:

| Kernel range | Verified by | Notes |
|---|---|---|
| 7.0.x (CachyOS) | CachyOS ships `MQ_IOSCHED_ADIOS` (same elevator API) in their Kconfig.iosched | Default target — use source as-is |
| 6.18 – 6.19 | ADIOS v3.2.0 patches for 6.18.3 use the same `(q, eq)` init_sched signature | Use source as-is |
| 6.12 – 6.17 | `init_sched` passes `elevator_type *` — ADIOS 6.12.44 patches confirm the old pattern | Apply `patches/0002-linux6.12-flow-iosched-compat.patch` after 0001 |
| 5.18 – 6.11 | `scoped_guard` / `guard` macros exist (cleanup.h added in 5.18), but `DEFINE_LOCK_GUARD_1(spinlock_irqsave)` availability is per-release | Untested — may work with additional backports |

The patch variants in `patches/` follow the approach used by
[ADIOS](https://github.com/firelzrd/adios) of shipping separate patches for
each kernel cycle.  If your kernel is not listed, check whether the
`init_sched` callback in your `elevator.h` matches the kernel‑7.x `(q, eq)`
signature or the older `(q, e)` signature and apply the corresponding patch.

When applying for kernel integration:

1. Apply `patches/0001-linux7.0-flow-iosched-v1.0.0.patch` — creates the
   scheduler source and adds Kconfig/Makefile/elevator entries.
2. For kernels 6.12 – 6.17, also apply
   `patches/0002-linux6.12-flow-iosched-compat.patch` to fix the
   `init_sched` callback signature.
3. Enable `CONFIG_MQ_IOSCHED_FLOW=m` (or `=y`) in your kernel config.
   Optionally enable `CONFIG_MQ_IOSCHED_DEFAULT_FLOW=y` to make
   flow-iosched the default scheduler on boot (this modifies
   `elevator_set_default()` in the kernel's `block/elevator.c`).
4. Build and install the kernel.

For runtime selection without recompiling, build as a standalone module:

```bash
cd block
make -C /lib/modules/$(uname -r)/build M=$(pwd)
sudo insmod flow-iosched.ko
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

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

## Design

At insertion time each request is classified into one of the lanes above based
on its `cmd_flags` (sync, meta, flush, priority) and the originating process's
I/O budget balance.  The scheduler maintains per-lane red-black trees keyed by
deadline, plus FIFO priority queues for the emergency and barrier tiers.

Dispatch walks lanes in priority order, pulling requests into batch-sized groups
before submitting to the device.  Starvation is tracked as round counters per
lane — when a lane accumulates enough consecutive bypasses the scheduler force-
dispatches from it, ensuring fairness without wall-clock timers.

Processes that exceed their I/O budget accumulate a containment score; once the
score passes the containment threshold their I/O is demoted to the contained
lane until the score decays below the threshold again.

For a more detailed walkthrough of the lane classification and starvation
tracking logic that flow-iosched adapts, see the
[scx_flow README](https://github.com/sched-ext/scx/tree/main/scheds/experimental/scx_flow).

## Production Ready?

For general-purpose desktop and workstation use on single-queue and moderate
multi-queue devices, yes.

flow-iosched has been reviewed through three rounds of static analysis
covering locking correctness, memory safety, race conditions, kernel API
compatibility, and starvation-edge correctness.  Its core scheduling paths
(reserved, latency, shared, and contained lanes) follow the same bounded
design that scx_flow uses for CPU scheduling, adapted to the block layer
through the blk-mq elevator API.

The current version (v1.0.0) is appropriate for daily use on SATA SSDs,
single-queue NVMe, and mid-range multi-queue NVMe devices (up to
approximately 8 hardware queues).  For high-end NVMe storage with 16 or
more queues, the blk-mq elevator API's single-queue dispatch model
(`QUEUE_FLAG_SQ_SCHED`) becomes a throughput bottleneck regardless of the
chosen I/O scheduler — this is a framework-level constraint shared by all
blk-mq schedulers including mq-deadline, Kyber, BFQ, and ADIOS.

## Credits

flow-iosched stands on the shoulders of several I/O and CPU scheduling
projects that shaped its design:

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
