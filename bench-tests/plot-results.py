#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Generate benchmark charts from run-benchmarks.sh output.
#
# Reads results/summary.csv and produces:
#   charts/iops.png        — IOPS comparison (grouped bar)
#   charts/latency.png     — latency comparison (grouped bar)
#   charts/per_workload.png — IOPS per scheduler (horizontal, one per workload)
#   charts/comparison.png  — Consolidated comparison (multiple metrics)

import csv
import os
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RESULTS = "results"
CHARTS = "charts"

CSV_PATH = os.path.join(RESULTS, "summary.csv")
if not os.path.isfile(CSV_PATH):
    print(f"ERROR: Results file not found at {CSV_PATH}", file=sys.stderr)
    print("Run run-benchmarks.sh first to generate benchmark data.", file=sys.stderr)
    sys.exit(1)

os.makedirs(CHARTS, exist_ok=True)

# ── Read measurement metadata ───────────────────────────────────────────
META_PATH = os.path.join(RESULTS, "metadata.txt")
MEASUREMENT_LABEL = ""
if os.path.isfile(META_PATH):
    meta = {}
    with open(META_PATH) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                meta[k] = v
    device_label = meta.get("label", meta.get("device", "unknown"))
    runtime = meta.get("runtime", "?")
    if meta.get("null_blk") == "true":
        MEASUREMENT_LABEL = f"Measured using {device_label} ({runtime}s per test)"
    else:
        MEASUREMENT_LABEL = f"Measured using {device_label} ({runtime}s per test)"
else:
    MEASUREMENT_LABEL = ""

# ── Color palette matching scx_flow benchmark style ───────────────────
COLOR_BY_SCHED = {
    "none":         "#4c72b0",
    "mq-deadline":  "#dd8452",
    "kyber":        "#55a868",
    "bfq":          "#c44e52",
    "adios":        "#8172b3",
    "flow-iosched": "#937860",
}
FALLBACK_COLORS = list(COLOR_BY_SCHED.values())

# ── Read data ─────────────────────────────────────────────────────────
rows = []
with open(CSV_PATH) as f:
    reader = csv.DictReader(f)
    for row in reader:
        try:
            row["read_iops"]  = int(float(row["read_iops"]))
            row["write_iops"] = int(float(row["write_iops"]))
            row["read_lat_us"]  = float(row["read_lat_us"])
            row["write_lat_us"] = float(row["write_lat_us"])
        except (ValueError, KeyError):
            continue
        rows.append(row)

schedulers = sorted(set(r["scheduler"] for r in rows))
if not schedulers:
    print("ERROR: No valid benchmark data found in summary.csv", file=sys.stderr)
    print("Check that run-benchmarks.sh completed successfully.", file=sys.stderr)
    sys.exit(1)
workloads = ["randread_4k", "randwrite_4k", "seqread_128k", "seqwrite_128k", "mixed_70_30"]
wl_labels = ["Rand Read\n4k", "Rand Write\n4k", "Seq Read\n128k", "Seq Write\n128k", "Mixed\n70/30"]

def color_for(sched):
    return COLOR_BY_SCHED.get(sched, FALLBACK_COLORS[len(schedulers) % len(FALLBACK_COLORS)])

def sort_scheds_by(metric, reverse=False):
    """Return schedulers sorted best-to-worst by a per-scheduler metric.
    metric(sched) returns a numeric value; reverse=True means higher is better."""
    return sorted(schedulers,
                  key=lambda s: metric(s),
                  reverse=reverse)

def workload_index(wl):
    try:
        return workloads.index(wl)
    except ValueError:
        return -1

# ── Helpers ───────────────────────────────────────────────────────────
def fmt_val(v):
    """Format a number for bar annotations: int for large, 1dp for small."""
    if v >= 1000:
        return f"{v:,.0f}"
    return f"{v:.1f}"

def add_measurement_label(fig):
    """Add a gray italic note at the bottom of the figure describing the test setup."""
    if MEASUREMENT_LABEL:
        fig.text(0.5, 0.01, MEASUREMENT_LABEL, ha="center",
                 fontsize=7, style="italic", color="gray")

def add_sorting_note(fig, note):
    """Add a gray italic sorting note below the suptitle."""
    fig.text(0.5, 0.93, note, ha="center", va="top", fontsize=7, style="italic", color="gray")

def annotate_bars(ax, bars, values, pad_ratio=0.02):
    """Annotate each bar with its value, offset slightly to the right."""
    max_val = max(abs(v) for v in values) if values else 1
    pad = max_val * pad_ratio if pad_ratio > 0 else 1
    for bar, val in zip(bars, values):
        if val == 0:
            continue
        ax.text(
            bar.get_width() + pad,
            bar.get_y() + bar.get_height() / 2,
            fmt_val(val),
            va="center", fontsize=6,
        )

# ── 1. IOPS chart (grouped bars, total IOPS per workload) ────────────
# Sort schedulers by total IOPS descending (best first)
def total_iops(sched):
    total = 0
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match:
            total += match[0]["read_iops"] + match[0]["write_iops"]
    return total

sched_order_iops = sort_scheds_by(total_iops, reverse=True)
fig, ax = plt.subplots(figsize=(10, 5))
x = np.arange(len(workloads))
width = 0.85 / max(len(sched_order_iops), 1)

for i, sched in enumerate(sched_order_iops):
    vals = []
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        vals.append(match[0]["read_iops"] + match[0]["write_iops"] if match else 0)
    bars = ax.bar(x + i * width, vals, width, label=sched, color=color_for(sched))
    annotate_bars(ax, bars, vals)

ax.set_ylabel("Total IOPS")
fig.suptitle("I/O Scheduler Comparison — Total IOPS", fontsize=12, fontweight="bold")
add_sorting_note(fig, "Sorted best to worst by average total IOPS (higher is better)")
ax.set_xticks(x + width * (len(schedulers) - 1) / 2)
ax.set_xticklabels(wl_labels)
ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.08), ncol=len(schedulers), fontsize=7)
ax.grid(axis="y", alpha=0.3)
ax.margins(x=0.15)
fig.subplots_adjust(top=0.90, bottom=0.16, right=0.92)
add_measurement_label(fig)
fig.savefig(f"{CHARTS}/iops.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/iops.png")

# ── 2. Latency chart (read latency, grouped bars) ────────────────────
# Sort schedulers by average read latency ascending (best first)
def avg_read_lat(sched):
    lats = []
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match and match[0]["read_iops"] > 0:
            lats.append(match[0]["read_lat_us"])
    return sum(lats) / len(lats) if lats else float("inf")

sched_order_lat = sort_scheds_by(avg_read_lat, reverse=False)
fig, ax = plt.subplots(figsize=(10, 5))
for i, sched in enumerate(sched_order_lat):
    vals = []
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match and match[0]["read_iops"] > 0:
            vals.append(match[0]["read_lat_us"])
        else:
            vals.append(0)
    bars = ax.bar(x + i * width, vals, width, label=sched, color=color_for(sched))
    # Latency values span ~25x range (BFQ outlier); skip annotations to
    # avoid overlapping text.  The log scale makes all bars readable.
    # annotate_bars(ax, bars, vals)

ax.set_ylabel("Read latency (µs)")
fig.suptitle("I/O Scheduler Comparison — Read Latency", fontsize=12, fontweight="bold")
add_sorting_note(fig, "Sorted best to worst by average read latency (lower is better)")
ax.set_xticks(x + width * (len(schedulers) - 1) / 2)
ax.set_xticklabels(wl_labels)
# Annotate write-only workloads (no read latency to show)
for wi, wl in enumerate(workloads):
    all_zero = all(
        row["read_iops"] == 0
        for row in rows if row["workload"] == wl
    )
    if all_zero:
        ax.text(x[wi] + width * (len(schedulers) - 1) / 2, 0.08,
                "write-only\n(no reads)", ha="center", va="bottom",
                fontsize=6, color="gray", transform=ax.get_xaxis_transform())
ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.08), ncol=len(schedulers), fontsize=7)
ax.grid(axis="y", alpha=0.3)
ax.set_yscale("log")
ax.margins(x=0.15)
fig.subplots_adjust(top=0.90, bottom=0.16, right=0.92)
add_measurement_label(fig)
fig.savefig(f"{CHARTS}/latency.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/latency.png")

# ── 3. Per-workload IOPS (horizontal bars, sorted best first per workload) ──
fig, axes = plt.subplots(1, len(workloads), figsize=(14, 4), sharey=True)
for wi, wl in enumerate(workloads):
    ax = axes[wi]
    pairs = []
    for sched in schedulers:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match:
            pairs.append((sched, match[0]["read_iops"] + match[0]["write_iops"]))
    pairs.sort(key=lambda p: p[1], reverse=True)
    scheds = [p[0] for p in pairs]
    iops = [p[1] for p in pairs]
    bars = ax.barh(range(len(scheds)), iops, color=[color_for(s) for s in scheds])
    ax.set_yticks(range(len(scheds)))
    ax.set_yticklabels(scheds, fontsize=7)
    ax.set_xlabel("IOPS")
    ax.set_title(wl_labels[wi].replace("\n", " "), fontsize=9)
    ax.grid(axis="x", alpha=0.3)
    for bar, val in zip(bars, iops):
        ax.text(bar.get_width() * 1.01, bar.get_y() + bar.get_height() / 2,
                fmt_val(val), va="center", fontsize=7)
fig.suptitle("Per-Workload IOPS", fontsize=12, fontweight="bold")
add_sorting_note(fig, "Sorted best to worst per workload (higher is better)")
fig.tight_layout(rect=(0, 0, 1, 0.90))
add_measurement_label(fig)
fig.savefig(f"{CHARTS}/per_workload.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/per_workload.png")

# ── 4. Consolidated comparison chart ─────────────────────────────────
# Follows the scx_flow pattern: one subplot per metric with direction annotation.
# Only averages over workloads that actually exercise the metric (e.g. read
# latency only from read workloads, write latency only from write workloads).
metrics = [
    ("Total IOPS",       "higher",
     lambda m: m["read_iops"] + m["write_iops"],
     None),  # all workloads qualify
    ("Read Latency (µs)","lower",
     lambda m: m["read_lat_us"],
     lambda m: m["read_iops"] > 0),  # only workloads with reads
    ("Write Latency (µs)","lower",
     lambda m: m["write_lat_us"],
     lambda m: m["write_iops"] > 0),  # only workloads with writes
]
fig, axes = plt.subplots(1, len(metrics), figsize=(14, 5), sharey=True)
if len(metrics) == 1:
    axes = [axes]

for ax_i, (title, direction, extractor, qualifies) in enumerate(metrics):
    ax = axes[ax_i]
    data_per_sched = []
    for sched in schedulers:
        vals = []
        for wl in workloads:
            match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
            if match and (qualifies is None or qualifies(match[0])):
                vals.append(extractor(match[0]))
        data_per_sched.append(sum(vals) / len(vals) if vals else 0)

    # Sort best to worst
    sorted_pairs = sorted(
        zip(schedulers, data_per_sched),
        key=lambda pair: pair[1],
        reverse=(direction == "higher"),
    )
    sorted_scheds = [p[0] for p in sorted_pairs]
    sorted_vals   = [p[1] for p in sorted_pairs]

    bars = ax.barh(range(len(sorted_scheds)), sorted_vals,
                   color=[color_for(s) for s in sorted_scheds])
    ax.set_yticks(range(len(sorted_scheds)))
    ax.set_yticklabels(sorted_scheds, fontsize=8)
    dir_label = "higher is better" if direction == "higher" else "lower is better"
    ax.set_title(f"{title}\n({dir_label})", fontsize=10)
    max_val = max(sorted_vals) if sorted_vals else 1
    ax.set_xlim(left=0, right=max_val * 1.2 or 1)
    ax.grid(axis="x", alpha=0.3)
    # Annotate bars with per-bar relative padding (matches per_workload style)
    for bar, val in zip(bars, sorted_vals):
        if val == 0:
            continue
        ax.text(bar.get_width() * 1.01, bar.get_y() + bar.get_height() / 2,
                fmt_val(val), va="center", fontsize=6)

fig.suptitle("I/O Scheduler Comparison — Consolidated Averages",
             fontsize=12, fontweight="bold")
add_sorting_note(fig, "Sorted best to worst per metric")
fig.tight_layout(rect=(0, 0, 1, 0.90))
add_measurement_label(fig)
fig.savefig(f"{CHARTS}/comparison.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/comparison.png")

print(f"\nAll charts saved to {CHARTS}/")
