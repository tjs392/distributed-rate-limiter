#!/usr/bin/env python3
"""
plot_results.py
Generates plots from convergence benchmark CSV results.

Usage:
    python3 plot_results.py
    python3 plot_results.py --csv path/to/convergence_combined.csv
"""

import argparse
import os
import sys
import statistics
import math

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
except ImportError:
    print("ERROR: matplotlib not installed. Run: pip install matplotlib")
    sys.exit(1)

import csv

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CSV = os.path.join(SCRIPT_DIR, "results", "convergence_combined.csv")
PLOTS_DIR   = os.path.join(SCRIPT_DIR, "results", "plots")

# Base strategies without velocity - ordered by tier count for diminishing-returns plots
BASE_STRATEGY_ORDER = [
    "tiered_1",
    "tiered_2",
    "tiered_5",
    "tiered_8",
    "continuous_k8",
]

# Velocity variants - grouped separately for the velocity sweep plot
VELOCITY_STRATEGIES = [
    "tiered_5_v0.4_va0.3",
    "tiered_8_v0.2_va0.3",
    "tiered_8_v0.4_va0.3",
    "tiered_8_v0.6_va0.3",
    "continuous_k8_v0.4_va0.3",
]

TIER_COUNTS = {
    "tiered_1":               1,
    "tiered_2":               2,
    "tiered_5":               5,
    "tiered_8":               8,
    "continuous_k8":          8,
    "tiered_5_v0.4_va0.3":   5,
    "tiered_8_v0.2_va0.3":   8,
    "tiered_8_v0.4_va0.3":   8,
    "tiered_8_v0.6_va0.3":   8,
    "continuous_k8_v0.4_va0.3": 8,
}

STRATEGY_LABELS = {
    "tiered_1":                  "Fixed (1 tier)",
    "tiered_2":                  "Binary (2 tiers)",
    "tiered_5":                  "5 Tiers",
    "tiered_8":                  "8 Tiers",
    "continuous_k8":             "Continuous (k=8)",
    "tiered_5_v0.4_va0.3":      "5 Tiers + vel(0.4)",
    "tiered_8_v0.2_va0.3":      "8 Tiers + vel(0.2)",
    "tiered_8_v0.4_va0.3":      "8 Tiers + vel(0.4)",
    "tiered_8_v0.6_va0.3":      "8 Tiers + vel(0.6)",
    "continuous_k8_v0.4_va0.3": "Continuous + vel(0.4)",
}

COLORS = {
    "tiered_1":                  "#4878CF",
    "tiered_2":                  "#D65F5F",
    "tiered_5":                  "#6ACC65",
    "tiered_8":                  "#B47CC7",
    "continuous_k8":             "#888888",
    "tiered_5_v0.4_va0.3":      "#3DAA5C",
    "tiered_8_v0.2_va0.3":      "#E0A0F0",
    "tiered_8_v0.4_va0.3":      "#9B30D0",
    "tiered_8_v0.6_va0.3":      "#5B0090",
    "continuous_k8_v0.4_va0.3": "#444444",
}

SENTINEL = 30000.0
LIMIT    = 1000


# ── Data loading ──────────────────────────────────────────────────────────────

def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            def flt(k, default=None):
                v = row.get(k, "")
                if v == "" or v is None:
                    return default
                try:
                    return float(v)
                except:
                    return default

            row["pressure"]             = flt("pressure", 0)
            row["requests"]             = int(row.get("requests", 0))
            row["iteration"]            = int(row.get("iteration", 0))
            row["allowed"]              = int(row.get("allowed", 0))
            row["denied"]               = int(row.get("denied", 0))
            row["over_admission_count"] = int(row.get("over_admission_count", 0))
            row["over_admission_ratio"] = flt("over_admission_ratio", 0)
            row["p75_ms"]               = flt("p75_ms", SENTINEL)
            row["max_ms"]               = flt("max_ms", SENTINEL)
            row["first_propagation_ms"] = flt("first_propagation_ms", SENTINEL)
            row["gossip_bytes"]         = flt("gossip_bytes", 0)
            row["gossip_msgs"]          = flt("gossip_msgs", 0)
            row["gossip_rounds"]        = flt("gossip_rounds", 0)
            row["empty_rounds"]         = flt("empty_rounds", 0)
            row["useful_ratio"]         = flt("useful_ratio", 0)
            row["cpu_pct"]              = flt("cpu_pct", 0)
            row["velocity_weight"]      = flt("velocity_weight", 0)
            row["velocity_alpha"]       = flt("velocity_alpha", 0.3)
            rows.append(row)
    return rows


def group_by(rows, key):
    out = {}
    for row in rows:
        out.setdefault(row[key], []).append(row)
    return out


def mean_std(values):
    if not values:
        return 0.0, 0.0
    m = statistics.mean(values)
    s = statistics.stdev(values) if len(values) > 1 else 0.0
    return m, s


def all_strategy_order(rows):
    """Return strategies in a consistent order: base first, velocity variants after."""
    seen = {r["strategy"] for r in rows}
    ordered = [s for s in BASE_STRATEGY_ORDER if s in seen]
    ordered += [s for s in VELOCITY_STRATEGIES if s in seen]
    # catch anything not in either list
    ordered += sorted(s for s in seen if s not in ordered)
    return ordered


def pressure_levels(rows):
    return sorted({r["requests"] for r in rows})


def label(s):
    return STRATEGY_LABELS.get(s, s)


def color(s):
    return COLORS.get(s, "#999999")


# ── Plot helpers ──────────────────────────────────────────────────────────────

def save(fig, name):
    os.makedirs(PLOTS_DIR, exist_ok=True)
    path = os.path.join(PLOTS_DIR, name)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  saved → {path}")


def pressure_label(requests):
    return f"{round(requests / LIMIT * 100)}%"


# ── Plot 1: OA ratio by pressure, base strategies only ───────────────────────

def plot_oa_by_pressure(rows):
    strategies = [s for s in all_strategy_order(rows) if s in BASE_STRATEGY_ORDER]
    levels     = pressure_levels(rows)
    by_strat   = group_by(rows, "strategy")

    fig, ax = plt.subplots(figsize=(9, 5))
    for s in strategies:
        xs, ys, errs = [], [], []
        for req in levels:
            vals = [r["over_admission_ratio"] for r in by_strat.get(s, []) if r["requests"] == req]
            if vals:
                m, sd = mean_std(vals)
                xs.append(req / LIMIT * 100)
                ys.append(m * 100)
                errs.append(sd * 100)
        ax.errorbar(xs, ys, yerr=errs, label=label(s), color=color(s),
                    marker="o", linewidth=2, markersize=5, capsize=3)

    ax.set_xlabel("Load (% of rate limit)", fontsize=11)
    ax.set_ylabel("Over-admission ratio (%)", fontsize=11)
    ax.set_title("Over-Admission Ratio - Base Strategies", fontsize=12)
    ax.xaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
    ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
    ax.axvline(100, color="gray", linestyle="--", linewidth=1, alpha=0.5)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "01_oa_base_strategies.png")


# ── Plot 2: OA ratio - velocity strategies vs their base counterparts ─────────

def plot_oa_velocity_comparison(rows):
    """
    Side-by-side: base 8tier and 5tier vs their velocity variants.
    Shows whether velocity improves OA.
    """
    compare_groups = [
        ("tiered_8",    ["tiered_8_v0.2_va0.3", "tiered_8_v0.4_va0.3", "tiered_8_v0.6_va0.3"]),
        ("tiered_5",    ["tiered_5_v0.4_va0.3"]),
        ("continuous_k8", ["continuous_k8_v0.4_va0.3"]),
    ]

    levels   = pressure_levels(rows)
    by_strat = group_by(rows, "strategy")
    present  = {r["strategy"] for r in rows}

    fig, axes = plt.subplots(1, len(compare_groups), figsize=(7 * len(compare_groups), 5), squeeze=False)

    for gi, (base, variants) in enumerate(compare_groups):
        ax = axes[0][gi]
        for s in [base] + variants:
            if s not in present:
                continue
            xs, ys, errs = [], [], []
            for req in levels:
                vals = [r["over_admission_ratio"] for r in by_strat.get(s, []) if r["requests"] == req]
                if vals:
                    m, sd = mean_std(vals)
                    xs.append(req / LIMIT * 100)
                    ys.append(m * 100)
                    errs.append(sd * 100)
            lw = 2.5 if s == base else 1.5
            ls = "-" if s == base else "--"
            ax.errorbar(xs, ys, yerr=errs, label=label(s), color=color(s),
                        marker="o", linewidth=lw, linestyle=ls, markersize=5, capsize=3)

        ax.set_xlabel("Load (% of rate limit)", fontsize=10)
        ax.set_ylabel("OA ratio (%)", fontsize=10)
        ax.set_title(f"{label(base)} - velocity comparison", fontsize=11)
        ax.xaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3)

    fig.suptitle("Velocity-Aware vs Baseline - OA Ratio", fontsize=13)
    fig.tight_layout()
    save(fig, "02_oa_velocity_comparison.png")


# ── Plot 3: First propagation latency ─────────────────────────────────────────

def plot_first_propagation(rows):
    """
    Mean first_propagation_ms per strategy at each pressure level.
    Sentinels excluded. This directly shows promotion latency effect.
    """
    strategies = all_strategy_order(rows)
    levels     = pressure_levels(rows)
    by_strat   = group_by(rows, "strategy")

    real_levels = [req for req in levels
                   if any(r["first_propagation_ms"] < SENTINEL
                          for s in strategies
                          for r in by_strat.get(s, [])
                          if r["requests"] == req)]
    if not real_levels:
        print("  [skip] all first_propagation values are sentinels")
        return

    fig, ax = plt.subplots(figsize=(10, 5))
    for s in strategies:
        xs, ys, errs = [], [], []
        for req in real_levels:
            vals = [r["first_propagation_ms"]
                    for r in by_strat.get(s, [])
                    if r["requests"] == req and r["first_propagation_ms"] < SENTINEL]
            if vals:
                m, sd = mean_std(vals)
                xs.append(req / LIMIT * 100)
                ys.append(m)
                errs.append(sd)
        if xs:
            lw = 2.5 if s in BASE_STRATEGY_ORDER else 1.5
            ls = "-" if s in BASE_STRATEGY_ORDER else "--"
            ax.errorbar(xs, ys, yerr=errs, label=label(s), color=color(s),
                        marker="o", linewidth=lw, linestyle=ls, markersize=5, capsize=3)

    ax.set_xlabel("Load (% of rate limit)", fontsize=11)
    ax.set_ylabel("First propagation latency (ms)", fontsize=11)
    ax.set_title("First Propagation Latency - Sentinels Excluded", fontsize=12)
    ax.xaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "03_first_propagation_latency.png")


# ── Plot 4: Bytes efficiency - bytes sent per OA reduction point ──────────────

def plot_bytes_efficiency(rows):
    """
    For each strategy at each pressure level:
    x = mean gossip_bytes, y = OA reduction vs fixed.
    Shows bandwidth efficiency - lower-left is better.
    """
    strategies = all_strategy_order(rows)
    levels     = [req for req in pressure_levels(rows) if req > LIMIT]
    by_strat   = group_by(rows, "strategy")
    fixed_rows = by_strat.get("tiered_1", [])

    if not fixed_rows:
        print("  [skip] bytes efficiency plot needs tiered_1 as baseline")
        return

    ncols = min(len(levels), 3)
    nrows = math.ceil(len(levels) / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(6 * ncols, 5 * nrows), squeeze=False)

    for idx, req in enumerate(levels):
        ax = axes[idx // ncols][idx % ncols]
        f_oa = statistics.mean(r["over_admission_ratio"] for r in fixed_rows if r["requests"] == req)
        f_oa = f_oa if f_oa > 0 else None

        for s in strategies:
            s_rows = [r for r in by_strat.get(s, []) if r["requests"] == req]
            if not s_rows or not f_oa:
                continue
            s_oa    = statistics.mean(r["over_admission_ratio"] for r in s_rows)
            s_bytes = statistics.mean(r["gossip_bytes"] for r in s_rows)
            reduction = (f_oa - s_oa) / f_oa * 100

            mk = "o" if s in BASE_STRATEGY_ORDER else "^"
            ax.scatter(s_bytes, reduction, color=color(s), s=80, marker=mk, zorder=5)
            ax.annotate(label(s), (s_bytes, reduction),
                        textcoords="offset points", xytext=(5, 3), fontsize=7, color=color(s))

        ax.set_xlabel("Mean gossip bytes per iteration", fontsize=10)
        ax.set_ylabel("OA reduction vs fixed (%)", fontsize=10)
        ax.set_title(f"Bytes Efficiency at {pressure_label(req)} load", fontsize=11)
        ax.grid(True, alpha=0.3)
        ax.axhline(0, color="gray", linewidth=0.8, alpha=0.5)

    for idx in range(len(levels), nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    fig.suptitle("Bandwidth Efficiency - Less bytes, more OA reduction = better (lower-left)", fontsize=12)
    fig.tight_layout()
    save(fig, "04_bytes_efficiency.png")


# ── Plot 5: Velocity weight sweep - OA vs velocity_weight for tiered_8 ───────

def plot_velocity_sweep(rows):
    """
    For tiered_8 variants, x = velocity_weight, y = mean OA ratio.
    One line per pressure level. Shows the optimal velocity weight.
    """
    levels   = [req for req in pressure_levels(rows) if req > LIMIT]
    by_strat = group_by(rows, "strategy")

    # collect all tiered_8 rows including velocity variants
    t8_strategies = [s for s in all_strategy_order(rows)
                     if s.startswith("tiered_8") or s == "tiered_2"]

    if len(t8_strategies) < 2:
        print("  [skip] velocity sweep needs multiple tiered_8 variants")
        return

    fig, ax = plt.subplots(figsize=(8, 5))

    level_colors = ["#D65F5F", "#E6A817", "#4878CF"]
    for li, req in enumerate(levels):
        xs, ys = [], []
        for s in t8_strategies:
            s_rows = [r for r in by_strat.get(s, []) if r["requests"] == req]
            if not s_rows:
                continue
            vw  = statistics.mean(r["velocity_weight"] for r in s_rows)
            oa  = statistics.mean(r["over_admission_ratio"] for r in s_rows) * 100
            xs.append(vw)
            ys.append(oa)

        if xs:
            paired = sorted(zip(xs, ys))
            xs_s   = [p[0] for p in paired]
            ys_s   = [p[1] for p in paired]
            c = level_colors[li % len(level_colors)]
            ax.plot(xs_s, ys_s, marker="o", linewidth=2, markersize=6,
                    color=c, label=f"{pressure_label(req)} load")

    # add binary as reference line
    for li, req in enumerate(levels):
        b_rows = [r for r in by_strat.get("tiered_2", []) if r["requests"] == req]
        if b_rows:
            b_oa = statistics.mean(r["over_admission_ratio"] for r in b_rows) * 100
            c = level_colors[li % len(level_colors)]
            ax.axhline(b_oa, color=c, linestyle=":", linewidth=1.2, alpha=0.6)

    ax.set_xlabel("Velocity weight (w2)", fontsize=11)
    ax.set_ylabel("Mean OA ratio (%)", fontsize=11)
    ax.set_title("8-Tier OA vs Velocity Weight\n(dotted = binary baseline at same load)", fontsize=12)
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "05_velocity_weight_sweep.png")


# ── Plot 6: OA heatmap - all strategies × pressure ───────────────────────────

def plot_oa_heatmap(rows):
    try:
        import numpy as np
    except ImportError:
        print("  [skip] heatmap requires numpy")
        return

    strategies = all_strategy_order(rows)
    levels     = pressure_levels(rows)
    by_strat   = group_by(rows, "strategy")

    matrix = []
    for s in strategies:
        row_vals = []
        for req in levels:
            vals = [r["over_admission_ratio"] for r in by_strat.get(s, []) if r["requests"] == req]
            row_vals.append(statistics.mean(vals) * 100 if vals else float("nan"))
        matrix.append(row_vals)

    data  = np.array(matrix)
    valid = data[~np.isnan(data)]
    if valid.size == 0:
        print("  [skip] heatmap has no valid data")
        return

    fig, ax = plt.subplots(figsize=(max(8, len(levels) * 1.5), max(4, len(strategies) * 0.6)))
    im = ax.imshow(data, aspect="auto", cmap="RdYlGn_r", vmin=0, vmax=valid.max())

    ax.set_xticks(range(len(levels)))
    ax.set_xticklabels([pressure_label(r) for r in levels])
    ax.set_yticks(range(len(strategies)))
    ax.set_yticklabels([label(s) for s in strategies], fontsize=8)
    ax.set_xlabel("Load (% of rate limit)", fontsize=11)
    ax.set_title("Over-Admission Ratio (%) - All Strategies × Load", fontsize=12)

    for i in range(len(strategies)):
        for j in range(len(levels)):
            val = data[i, j]
            if not np.isnan(val):
                ax.text(j, i, f"{val:.0f}%", ha="center", va="center",
                        fontsize=8, color="black" if val < 150 else "white")

    fig.colorbar(im, ax=ax, label="OA ratio (%)")
    fig.tight_layout()
    save(fig, "06_oa_heatmap_all.png")


# ── Plot 7: Per-iteration OA variance ────────────────────────────────────────

def plot_oa_variance(rows):
    strategies = all_strategy_order(rows)
    levels     = [req for req in pressure_levels(rows) if req > LIMIT]
    by_strat   = group_by(rows, "strategy")

    if not levels:
        return

    ncols = min(len(levels), 2)
    nrows = math.ceil(len(levels) / ncols)
    fig, axes = plt.subplots(nrows, ncols, figsize=(max(10, len(strategies)) * ncols, 5 * nrows), squeeze=False)

    for idx, req in enumerate(levels):
        ax = axes[idx // ncols][idx % ncols]
        for si, s in enumerate(strategies):
            vals = [r["over_admission_ratio"] * 100
                    for r in by_strat.get(s, []) if r["requests"] == req]
            if vals:
                jitter = [(si + 1) + (i - len(vals) / 2) * 0.05 for i in range(len(vals))]
                ax.scatter(jitter, vals, color=color(s), alpha=0.7, s=50, zorder=4)
                ax.hlines(statistics.mean(vals), si + 0.75, si + 1.25,
                          colors=color(s), linewidth=2.5)

        ax.set_xticks(range(1, len(strategies) + 1))
        ax.set_xticklabels([label(s) for s in strategies], rotation=30, ha="right", fontsize=7)
        ax.set_ylabel("OA ratio (%)", fontsize=10)
        ax.set_title(f"Per-iteration OA variance at {pressure_label(req)} load", fontsize=11)
        ax.grid(True, axis="y", alpha=0.3)

    for idx in range(len(levels), nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    fig.suptitle("OA Variance - Each dot = 1 iteration, bar = mean", fontsize=12)
    fig.tight_layout()
    save(fig, "07_oa_variance.png")


# ── Plot 8: CPU % by strategy ─────────────────────────────────────────────────

def plot_cpu(rows):
    strategies = all_strategy_order(rows)
    levels     = pressure_levels(rows)
    by_strat   = group_by(rows, "strategy")

    fig, ax = plt.subplots(figsize=(9, 5))
    for s in strategies:
        xs, ys = [], []
        for req in levels:
            vals = [r["cpu_pct"] for r in by_strat.get(s, [])
                    if r["requests"] == req and r["cpu_pct"] > 0]
            if vals:
                xs.append(req / LIMIT * 100)
                ys.append(statistics.mean(vals))
        if xs:
            lw = 2 if s in BASE_STRATEGY_ORDER else 1.5
            ls = "-" if s in BASE_STRATEGY_ORDER else "--"
            ax.plot(xs, ys, marker="o", linewidth=lw, linestyle=ls,
                    color=color(s), label=label(s), markersize=5)

    ax.set_xlabel("Load (% of rate limit)", fontsize=11)
    ax.set_ylabel("CPU usage (%)", fontsize=11)
    ax.set_title("System CPU Usage by Strategy and Load", fontsize=12)
    ax.xaxis.set_major_formatter(mticker.FormatStrFormatter("%g%%"))
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    save(fig, "08_cpu_usage.png")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default=DEFAULT_CSV, help="Path to combined CSV")
    args = parser.parse_args()

    if not os.path.exists(args.csv):
        print(f"ERROR: CSV not found: {args.csv}")
        sys.exit(1)

    print(f"Loading {args.csv}")
    rows = load_csv(args.csv)
    strats = sorted({r["strategy"] for r in rows})
    print(f"  {len(rows)} rows, {len(strats)} strategies: {strats}")
    print(f"Generating plots → {PLOTS_DIR}/")

    plot_oa_by_pressure(rows)
    plot_oa_velocity_comparison(rows)
    plot_first_propagation(rows)
    plot_bytes_efficiency(rows)
    plot_velocity_sweep(rows)
    plot_oa_heatmap(rows)
    plot_oa_variance(rows)
    plot_cpu(rows)

    print("\nDone. All plots saved.")


if __name__ == "__main__":
    main()