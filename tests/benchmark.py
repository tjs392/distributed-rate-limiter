#!/usr/bin/env python3
"""
Convergence benchmark for pressure-tiered gossip.
Strategies are defined as (tier_count, alpha, continuous, velocity_weight, velocity_alpha) tuples.
tier_count=1 is fixed behavior, continuous=True uses curve sampling.
"""

import asyncio
import aiohttp
import time
import random
import csv
import os
import subprocess
import sys
import statistics
import re

NODES = [
    "http://localhost:8080",
    "http://localhost:8081",
    "http://localhost:8082",
    "http://localhost:8083",
    "http://localhost:8084",
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
CONFIG_DIR  = os.path.join(PROJECT_DIR, "config")
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")
RESTART_SCRIPT = os.path.join(SCRIPT_DIR, "restart.sh")
os.makedirs(RESULTS_DIR, exist_ok=True)

LIMIT              = 1000
WINDOW_MS          = 60000
PRESSURE_LEVELS    = [2000, 3000, 4000]
ITERATIONS         = 5
POLL_INTERVAL_MS   = 10
CONVERGENCE_TIMEOUT_S = 30
METRICS_PORTS = [9090, 9091, 9092, 9093, 9094]

# (tier_count, alpha, continuous, velocity_weight, velocity_alpha)
STRATEGIES = [
    # baselines
    (1,  2.0, False, 0.0, 0.3),   # fixed
    (2,  2.0, False, 0.0, 0.3),   # binary
    (5,  2.0, False, 0.0, 0.3),   # 5tier baseline
    (8,  2.0, False, 0.0, 0.3),   # 8tier baseline
    (8,  2.0, True,  0.0, 0.3),   # continuous baseline
    # velocity weight sweep (tiered_8, alpha_ema=0.3)
    (8,  2.0, False, 0.2, 0.3),
    (8,  2.0, False, 0.4, 0.3),
    (8,  2.0, False, 0.6, 0.3),
    (8,  2.0, False, 0.8, 0.3),
    (8,  2.0, False, 1.0, 0.3),
    # EMA alpha sweep (tiered_8, velocity_weight=0.6)
    (8,  2.0, False, 0.6, 0.1),
    (8,  2.0, False, 0.6, 0.5),
    (8,  2.0, False, 0.6, 0.7),
    (8,  2.0, False, 0.6, 0.9),
    # tier count sweep (velocity_weight=0.6, alpha_ema=0.3)
    (2,  2.0, False, 0.6, 0.3),
    (3,  2.0, False, 0.6, 0.3),
    (5,  2.0, False, 0.6, 0.3),
    (12, 2.0, False, 0.6, 0.3),
    # continuous + velocity
    (8,  2.0, True,  0.4, 0.3),
]


def strategy_label(tier_count, alpha, continuous, velocity_weight, velocity_alpha):
    base = f"continuous_k{tier_count}" if continuous else f"tiered_{tier_count}"
    if velocity_weight > 0.0:
        return f"{base}_v{velocity_weight}_va{velocity_alpha}"
    return base


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def set_strategy(tier_count, alpha, continuous, velocity_weight, velocity_alpha):
    cont_str = "true" if continuous else "false"
    for fname in os.listdir(CONFIG_DIR):
        if not fname.endswith(".toml"):
            continue
        path = os.path.join(CONFIG_DIR, fname)
        with open(path, "r") as f:
            content = f.read()
        content = re.sub(r'tier_count\s*=\s*\d+',        f'tier_count = {tier_count}',           content)
        content = re.sub(r'alpha\s*=\s*[\d.]+',           f'alpha = {alpha}',                     content)
        content = re.sub(r'continuous\s*=\s*\w+',         f'continuous = {cont_str}',              content)
        content = re.sub(r'velocity_weight\s*=\s*[\d.]+', f'velocity_weight = {velocity_weight}',  content)
        content = re.sub(r'velocity_alpha\s*=\s*[\d.]+',  f'velocity_alpha = {velocity_alpha}',    content)
        with open(path, "w") as f:
            f.write(content)
    log(f"Set configs to {strategy_label(tier_count, alpha, continuous, velocity_weight, velocity_alpha)}")


def restart_cluster():
    log("Restarting cluster...")
    subprocess.run(["bash", RESTART_SCRIPT], capture_output=True, timeout=120)
    import urllib.request
    for i in range(15):
        try:
            resp = urllib.request.urlopen("http://localhost:8080/health", timeout=2)
            if b"node_id" in resp.read():
                time.sleep(3)
                log("Cluster ready")
                return True
        except:
            pass
        time.sleep(1)
    log("WARNING: cluster not ready")
    return False


def read_cpu_times():
    with open("/proc/stat") as f:
        line = f.readline()
    fields = line.split()
    idle  = int(fields[4])
    total = sum(int(x) for x in fields[1:8])
    return idle, total


def cpu_percent(before, after):
    idle_delta  = after[0] - before[0]
    total_delta = after[1] - before[1]
    if total_delta == 0:
        return 0.0
    return round((1 - idle_delta / total_delta) * 100, 1)


async def scrape_metric(session, port, metric_name):
    try:
        async with session.get(
            f"http://localhost:{port}/metrics",
            timeout=aiohttp.ClientTimeout(total=2)
        ) as resp:
            text = await resp.text()
            for line in text.splitlines():
                if line.startswith(metric_name) and not line.startswith("#"):
                    return float(line.split()[-1])
    except:
        return None
    return None


async def scrape_gossip_msgs(session):
    total = 0.0
    for port in METRICS_PORTS:
        val = await scrape_metric(session, port, "gossip_messages_sent_total")
        if val is not None:
            total += val
    return total


async def scrape_gossip_bytes(session):
    total = 0.0
    for port in METRICS_PORTS:
        val = await scrape_metric(session, port, "gossip_bytes_sent_total")
        if val is not None:
            total += val
    return total


async def scrape_gossip_rounds(session):
    total = 0.0
    empty = 0.0
    for port in METRICS_PORTS:
        t = await scrape_metric(session, port, "gossip_rounds_total")
        e = await scrape_metric(session, port, "gossip_rounds_empty_total")
        if t is not None:
            total += t
        if e is not None:
            empty += e
    return total, empty


async def send_requests_distributed(session, key, count):
    MAX_CONCURRENCY = 500
    sem = asyncio.Semaphore(MAX_CONCURRENCY)

    async def one_request():
        async with sem:
            try:
                async with session.post(
                    f"{random.choice(NODES)}/check",
                    json={"key": key, "limit": LIMIT, "hits": 1, "window_ms": WINDOW_MS},
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    body = await resp.json()
                    return body.get("status") == 200
            except Exception:
                return None

    results = await asyncio.gather(*[one_request() for _ in range(count)])
    allowed = sum(1 for r in results if r is True)
    denied  = sum(1 for r in results if r is False)
    return allowed, denied


async def get_estimate(session, node, key):
    try:
        async with session.post(f"{node}/estimate", json={
            "key": key, "limit": LIMIT, "window_ms": WINDOW_MS,
        }, timeout=aiohttp.ClientTimeout(total=2)) as resp:
            body = await resp.json()
            return body.get("estimate", 0.0)
    except:
        return None


async def measure_convergence(session, num_requests):
    key = f"bench_{random.randint(0, 2**63)}"

    burst_start = time.monotonic()
    allowed, denied = await send_requests_distributed(session, key, num_requests)
    burst_duration_ms = (time.monotonic() - burst_start) * 1000
    send_done = time.monotonic()

    over_admission_count = max(0, allowed - LIMIT)
    over_admission_ratio = over_admission_count / LIMIT

    observers = NODES[1:]
    converged = [False] * len(observers)
    convergence_times     = [CONVERGENCE_TIMEOUT_S * 1000.0] * len(observers)
    convergence_pressures = [None] * len(observers)
    threshold = num_requests * 0.8
    deadline  = send_done + CONVERGENCE_TIMEOUT_S

    while time.monotonic() < deadline:
        if all(converged):
            break
        checks = []
        for i, node in enumerate(observers):
            if not converged[i]:
                checks.append((i, asyncio.create_task(get_estimate(session, node, key))))
        for i, task in checks:
            estimate = await task
            if estimate is not None and estimate >= threshold:
                converged[i] = True
                convergence_times[i]     = (time.monotonic() - send_done) * 1000
                convergence_pressures[i] = round(estimate / LIMIT, 3)
        await asyncio.sleep(POLL_INTERVAL_MS / 1000)

    sorted_times = sorted(convergence_times)
    return {
        "pressure":             num_requests / LIMIT,
        "requests":             num_requests,
        "allowed":              allowed,
        "denied":               denied,
        "over_admission_count": over_admission_count,
        "over_admission_ratio": round(over_admission_ratio, 4),
        "burst_duration_ms":    round(burst_duration_ms, 1),
        "node2_ms":             round(convergence_times[0], 1),
        "node3_ms":             round(convergence_times[1], 1),
        "node4_ms":             round(convergence_times[2], 1),
        "node5_ms":             round(convergence_times[3], 1),
        "node2_pressure":       convergence_pressures[0],
        "node3_pressure":       convergence_pressures[1],
        "node4_pressure":       convergence_pressures[2],
        "node5_pressure":       convergence_pressures[3],
        "p75_ms":               round(sorted_times[2], 1),
        "max_ms":               round(sorted_times[3], 1),
        "first_propagation_ms": round(min(convergence_times), 1),
    }


async def run_benchmark(tier_count, alpha, continuous, velocity_weight, velocity_alpha):
    label = strategy_label(tier_count, alpha, continuous, velocity_weight, velocity_alpha)
    log(f"Benchmarking {label}")
    results = []

    connector = aiohttp.TCPConnector(limit=500)
    async with aiohttp.ClientSession(connector=connector) as session:
        try:
            async with session.get(
                f"{NODES[0]}/health", timeout=aiohttp.ClientTimeout(total=5)
            ) as resp:
                if resp.status != 200:
                    log("ERROR: cluster not healthy")
                    return results
        except Exception as e:
            log(f"ERROR: {e}")
            return results

        for num_requests in PRESSURE_LEVELS:
            pressure      = num_requests / LIMIT
            p75s          = []
            oa_ratios     = []
            gossip_deltas = []

            for iteration in range(ITERATIONS):
                cpu_before    = read_cpu_times()
                msgs_before   = await scrape_gossip_msgs(session)
                bytes_before  = await scrape_gossip_bytes(session)
                rounds_before = await scrape_gossip_rounds(session)

                result = await measure_convergence(session, num_requests)

                msgs_after   = await scrape_gossip_msgs(session)
                bytes_after  = await scrape_gossip_bytes(session)
                rounds_after = await scrape_gossip_rounds(session)
                cpu_after    = read_cpu_times()

                gossip_delta  = round(msgs_after - msgs_before, 0)
                bytes_delta   = round(bytes_after - bytes_before, 0)
                rounds_delta  = rounds_after[0] - rounds_before[0]
                empty_delta   = rounds_after[1] - rounds_before[1]
                useful_ratio  = round((rounds_delta - empty_delta) / rounds_delta, 3) if rounds_delta > 0 else None

                result["iteration"]       = iteration
                result["strategy"]        = label
                result["tier_count"]      = tier_count
                result["alpha"]           = alpha
                result["continuous"]      = continuous
                result["velocity_weight"] = velocity_weight
                result["velocity_alpha"]  = velocity_alpha
                result["gossip_msgs"]     = gossip_delta
                result["gossip_bytes"]    = bytes_delta
                result["gossip_rounds"]   = round(rounds_delta, 0)
                result["empty_rounds"]    = round(empty_delta, 0)
                result["useful_ratio"]    = useful_ratio
                result["cpu_pct"]         = cpu_percent(cpu_before, cpu_after)

                results.append(result)
                p75s.append(result["p75_ms"])
                oa_ratios.append(result["over_admission_ratio"])
                if gossip_delta is not None:
                    gossip_deltas.append(gossip_delta)

                gossip_str = f"  gossip={gossip_delta:.0f}" if gossip_delta is not None else ""
                sys.stdout.write(
                    f"\r  {pressure:.0%} pressure: "
                    f"iter {iteration+1}/{ITERATIONS}  "
                    f"p75={result['p75_ms']:.0f}ms  "
                    f"max={result['max_ms']:.0f}ms  "
                    f"over_admission={result['over_admission_ratio']:.1%}"
                    f"{gossip_str}"
                )
                sys.stdout.flush()
                await asyncio.sleep(1)

            avg_p75    = statistics.mean(p75s)
            med_p75    = statistics.median(p75s)
            avg_oa     = statistics.mean(oa_ratios)
            avg_gossip = statistics.mean(gossip_deltas) if gossip_deltas else 0
            print(
                f"\n  => avg p75={avg_p75:.0f}ms  median p75={med_p75:.0f}ms  "
                f"avg over_admission={avg_oa:.1%}  avg gossip_msgs={avg_gossip:.0f}"
            )

    return results


def write_csv(results, filename):
    path = os.path.join(RESULTS_DIR, filename)
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "strategy", "tier_count", "alpha", "continuous",
            "velocity_weight", "velocity_alpha",
            "pressure", "requests", "iteration",
            "allowed", "denied", "over_admission_count", "over_admission_ratio",
            "burst_duration_ms",
            "gossip_msgs", "gossip_bytes", "gossip_rounds", "empty_rounds", "useful_ratio",
            "cpu_pct",
            "node2_ms", "node3_ms", "node4_ms", "node5_ms",
            "node2_pressure", "node3_pressure", "node4_pressure", "node5_pressure",
            "p75_ms", "max_ms", "first_propagation_ms",
        ])
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    log(f"Wrote {len(results)} rows to {path}")


def print_comparison(all_results):
    labels    = [strategy_label(*s) for s in STRATEGIES]
    present   = [l for l in labels if l in all_results]
    fixed_lbl = strategy_label(1, 2.0, False, 0.0, 0.3)
    fixed     = all_results.get(fixed_lbl, [])
    col_w     = 13

    header = "  " + f"{'Pressure':<10}" + "".join(
        f"  {(l + ' OA%'):>{col_w}}" for l in present
    )
    sep = "=" * len(header)
    print("\n" + sep)
    print("  OVER-ADMISSION RATIO PER STRATEGY")
    print(sep)
    print(header)
    print("-" * len(header))

    for num_requests in PRESSURE_LEVELS:
        pressure = num_requests / LIMIT
        row = "  " + f"{str(round(pressure * 100)) + '%':<10}"
        for l in present:
            rows = [r for r in all_results[l] if r["requests"] == num_requests]
            if rows:
                oa_avg = statistics.mean(r["over_admission_ratio"] for r in rows)
                row += f"  {oa_avg:>{col_w}.1%}"
            else:
                row += f"  {'N/A':>{col_w}}"
        print(row)
    print(sep)

    non_fixed = [l for l in present if l != fixed_lbl]
    if not fixed or not non_fixed:
        return

    print("\n  OA REDUCTION VS FIXED")
    header2 = "  " + f"{'Pressure':<10}" + "".join(f"  {l:>{col_w}}" for l in non_fixed)
    print(header2)
    print("-" * len(header2))

    for num_requests in PRESSURE_LEVELS:
        pressure = num_requests / LIMIT
        f_rows   = [r for r in fixed if r["requests"] == num_requests]
        f_oa     = statistics.mean(r["over_admission_ratio"] for r in f_rows) if f_rows else None
        row = "  " + f"{str(round(pressure * 100)) + '%':<10}"
        for l in non_fixed:
            rows = [r for r in all_results[l] if r["requests"] == num_requests]
            if rows and f_oa and f_oa > 0:
                s_oa = statistics.mean(r["over_admission_ratio"] for r in rows)
                row += f"  {(f_oa - s_oa) / f_oa:>{col_w}.1%}"
            elif rows and f_oa == 0:
                row += f"  {'(no OA)':>{col_w}}"
            else:
                row += f"  {'N/A':>{col_w}}"
        print(row)
    print()


async def main():
    start = time.monotonic()
    all_results = {}

    for tier_count, alpha, continuous, velocity_weight, velocity_alpha in STRATEGIES:
        set_strategy(tier_count, alpha, continuous, velocity_weight, velocity_alpha)
        restart_cluster()
        results = await run_benchmark(tier_count, alpha, continuous, velocity_weight, velocity_alpha)
        label = strategy_label(tier_count, alpha, continuous, velocity_weight, velocity_alpha)
        all_results[label] = results
        write_csv(results, f"convergence_{label}.csv")

    set_strategy(5, 2.0, False, 0.0, 0.3)

    print_comparison(all_results)

    combined = [r for results in all_results.values() for r in results]
    write_csv(combined, "convergence_combined.csv")

    elapsed = time.monotonic() - start
    print(f"\nDone in {elapsed/60:.1f} minutes. Results in {RESULTS_DIR}/")


if __name__ == "__main__":
    asyncio.run(main())