#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# Generate benchmark charts from run-benchmarks.sh output.
#
# Reads results/summary.csv and produces:
#   charts/iops.png        — IOPS comparison (grouped bar)
#   charts/latency.png     — latency comparison (grouped bar)
#   charts/comparison.png  — IOPS per scheduler (horizontal, one per workload)

import csv
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

RESULTS = "results"
CHARTS = "charts"
os.makedirs(CHARTS, exist_ok=True)

# Read data
rows = []
with open(f"{RESULTS}/summary.csv") as f:
    reader = csv.DictReader(f)
    for row in reader:
        row["read_iops"] = int(row["read_iops"])
        row["write_iops"] = int(row["write_iops"])
        row["read_lat_us"] = float(row["read_lat_us"])
        row["write_lat_us"] = float(row["write_lat_us"])
        rows.append(row)

schedulers = sorted(set(r["scheduler"] for r in rows))
workloads = ["randread_4k", "randwrite_4k", "seqread_128k", "seqwrite_128k", "mixed_70_30"]
wl_labels = ["Rand Read\n4k", "Rand Write\n4k", "Seq Read\n128k", "Seq Write\n128k", "Mixed\n70/30"]
colors = ["#4c72b0", "#dd8452", "#55a868", "#c44e52", "#8172b3", "#937860"]

# ---- IOPS chart ----
fig, ax = plt.subplots(figsize=(10, 5))
x = np.arange(len(workloads))
width = 0.12

for i, sched in enumerate(schedulers):
    vals = []
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        vals.append(match[0]["read_iops"] + match[0]["write_iops"] if match else 0)
    ax.bar(x + i * width, vals, width, label=sched, color=colors[i % len(colors)])

ax.set_ylabel("Total IOPS")
ax.set_title("I/O Scheduler Comparison — IOPS (higher is better)")
ax.set_xticks(x + width * (len(schedulers) - 1) / 2)
ax.set_xticklabels(wl_labels)
ax.legend(loc="upper left", fontsize=8)
ax.grid(axis="y", alpha=0.3)
fig.tight_layout()
fig.savefig(f"{CHARTS}/iops.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/iops.png")

# ---- Latency chart ----
fig, ax = plt.subplots(figsize=(10, 5))
for i, sched in enumerate(schedulers):
    vals = []
    for wl in workloads:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match and match[0]["read_iops"] > 0:
            vals.append(match[0]["read_lat_us"])
        else:
            vals.append(0)
    ax.bar(x + i * width, vals, width, label=sched, color=colors[i % len(colors)])

ax.set_ylabel("Read latency (µs)")
ax.set_title("I/O Scheduler Comparison — Read Latency (lower is better)")
ax.set_xticks(x + width * (len(schedulers) - 1) / 2)
ax.set_xticklabels(wl_labels)
ax.legend(loc="upper left", fontsize=8)
ax.grid(axis="y", alpha=0.3)
fig.tight_layout()
fig.savefig(f"{CHARTS}/latency.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/latency.png")

# ---- Per-scheduler IOPS ----
fig, axes = plt.subplots(1, len(workloads), figsize=(14, 4), sharey=True)
for wi, wl in enumerate(workloads):
    ax = axes[wi]
    scheds = []
    iops = []
    for sched in schedulers:
        match = [r for r in rows if r["scheduler"] == sched and r["workload"] == wl]
        if match:
            scheds.append(sched)
            iops.append(match[0]["read_iops"] + match[0]["write_iops"])
    bars = ax.barh(range(len(scheds)), iops, color=colors[:len(scheds)])
    ax.set_yticks(range(len(scheds)))
    ax.set_yticklabels(scheds, fontsize=7)
    ax.set_xlabel("IOPS")
    ax.set_title(wl_labels[wi].replace("\n", " "), fontsize=9)
    ax.grid(axis="x", alpha=0.3)
fig.suptitle("Per-Workload IOPS (higher is better)", fontsize=12)
fig.tight_layout()
fig.savefig(f"{CHARTS}/per_workload.png", dpi=150)
plt.close(fig)
print(f"  → {CHARTS}/per_workload.png")

print(f"\nCharts saved to {CHARTS}/")
