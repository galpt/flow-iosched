# Contributing

Thank you for your interest in flow-iosched.  This project is maintained as
a focused, single-owner scheduler that adapts the scx_flow lane design to
the block layer.  Contributions are handled through a controlled process to
keep the codebase stable for everyone who depends on it.

## Pull Requests

Pull requests are not accepted at this time.  The project has a small
maintenance surface and needs to stay reviewable without the overhead of
unsolicited changes that cannot be independently validated before merging.

If you have a change in mind — a bug fix, a performance improvement, or a
new feature — please open an issue first to discuss it.  That way we can
agree on the approach before any code is written, and if the change is
something the project will take, the maintainer can implement it directly
or work with you on a branch.

## Issues

The [issue tracker](https://github.com/galpt/flow-iosched/issues) is open
for:

- **Bug reports** — include the kernel version, the device type, the
  scheduler's sysfs state at the time of the issue, and steps to reproduce
  if possible.
- **Feature requests** — describe the problem you are trying to solve and
  how the scheduler currently falls short.
- **Performance observations** — if you happen to benchmark flow-iosched
  against other schedulers, sharing the results is always appreciated.

### Publishing Benchmark Results

Independent benchmark reports are welcome.  If you run comparisons of
flow-iosched against other I/O schedulers, please include the following
information in your report — it helps others reproduce and validate:

- Full hardware description (CPU, memory, storage model)
- Kernel version and scheduler configuration
- `fio` job files or equivalent workload description
- The exact tunable values used

Open an [issue](https://github.com/galpt/flow-iosched/issues) to share
results or link to a gist.

When reporting a bug, please include the output of:

```bash
cat /sys/block/<device>/queue/scheduler
cat /sys/block/<device>/queue/iosched/flow_version
uname -r
```

This helps narrow down whether the issue is in the scheduler itself or in
the kernel/blk-mq layer it runs on.

## Code of Conduct

This project adheres to the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you are expected to uphold its terms. Report unacceptable
behaviour to **galpt@v.recipes**.
