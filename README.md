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

## Building

The scheduler is implemented as a `blk-mq` elevator module.  To build it as a
standalone kernel module against your running kernel:

```bash
cd block
make
sudo insmod flow-iosched.ko
echo flow-iosched | sudo tee /sys/block/<device>/queue/scheduler
```

To integrate permanently, apply the patches from `patches/` against a kernel
tree and enable `CONFIG_MQ_IOSCHED_FLOW` / `CONFIG_MQ_IOSCHED_DEFAULT_FLOW`.

## Sysfs Tunables

Attributes under `/sys/block/<device>/queue/iosched/`:

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `flow_version` | RO | — | Current scheduler version |
| `read_priority` | RW | 7 | Read bias vs writes at same deadline (-20 to 19) |
| `sync_budget_sectors` | RW | 256 | Reserved lane budget per sync dispatch |
| `async_budget_sectors` | RW | 1024 | Shared lane budget per async dispatch |
| `batch_max_read` | RW | 36 | Max read requests per batch |
| `batch_max_write` | RW | 72 | Max write requests per batch |
| `completion_window_ns` | RW | 16000000 | Dispatch batch window (nanoseconds) |
| `starvation_max_reserved` | RW | 5 | Reserved starvation rounds before forced rotation |
| `starvation_max_shared` | RW | 12 | Shared starvation rounds before forced dispatch |
| `starvation_max_contained` | RW | 6 | Contained starvation rounds before rescue |
| `contain_threshold` | RW | 3 | Hog containment activation score |
| `contain_decay_step` | RW | 1 | Containment score decay per idle interval |

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

## Licence

GNU General Public License v2.0 only.  See [LICENSE](LICENSE).
