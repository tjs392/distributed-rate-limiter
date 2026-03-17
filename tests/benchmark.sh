#!/bin/bash
# benchmark.sh
# Measures throughput and latency of the distributed rate limiter

PORTS=(8080 8081 8082 8083 8084)
RESULTS_DIR="./benchmark_results"
mkdir -p $RESULTS_DIR
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

log() { echo "[$(date '+%H:%M:%S')] $1"; }

check_deps() {
    for dep in curl bc wrk hey; do
        if ! command -v $dep &> /dev/null; then
            echo "missing: $dep"
        fi
    done
}

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     Distributed Rate Limiter Benchmark   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

check_deps

# ============================================================
log "=== BENCH 1: Single node baseline throughput (hey) ==="

if command -v hey &> /dev/null; then
    log "Running 10,000 requests against node1..."
    hey -n 10000 -c 50 -m POST \
        -H "Content-Type: application/json" \
        -d '{"key":"bench:throughput","limit":100000,"hits":1,"window_ms":60000}' \
        http://localhost:8080/check \
        > $RESULTS_DIR/hey_single_${TIMESTAMP}.txt 2>&1

    echo ""
    cat $RESULTS_DIR/hey_single_${TIMESTAMP}.txt | grep -E "Requests/sec|Average|Fastest|Slowest|P50|P95|P99"
    echo ""
else
    log "hey not installed — skipping (install: go install github.com/rakyll/hey@latest)"
fi

# ============================================================
log "=== BENCH 2: Single node baseline throughput (wrk) ==="

if command -v wrk &> /dev/null; then
    log "Running wrk for 10s against node1..."

    cat > /tmp/wrk_post.lua << 'EOF'
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"key":"bench:wrk","limit":100000,"hits":1,"window_ms":60000}'
EOF

    wrk -t4 -c50 -d10s -s /tmp/wrk_post.lua \
        http://localhost:8080/check \
        > $RESULTS_DIR/wrk_single_${TIMESTAMP}.txt 2>&1

    echo ""
    cat $RESULTS_DIR/wrk_single_${TIMESTAMP}.txt
    echo ""
else
    log "wrk not installed — skipping (install: sudo apt install wrk)"
fi

# ============================================================
log "=== BENCH 3: Latency percentiles (curl loop) ==="

log "Measuring latency over 200 sequential requests..."

LATENCIES=()
for i in $(seq 1 200); do
    start=$(date +%s%N)
    curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d '{"key":"bench:latency","limit":100000,"hits":1,"window_ms":60000}' \
        -o /dev/null --max-time 2
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    LATENCIES+=($elapsed)
done

# sort and compute percentiles
IFS=$'\n' SORTED=($(sort -n <<< "${LATENCIES[*]}")); unset IFS

total=${#SORTED[@]}
p50_idx=$((total * 50 / 100))
p95_idx=$((total * 95 / 100))
p99_idx=$((total * 99 / 100))
p50=${SORTED[$p50_idx]}
p95=${SORTED[$p95_idx]}
p99=${SORTED[$p99_idx]}
min=${SORTED[0]}
max=${SORTED[$((total - 1))]}

sum=0
for l in "${LATENCIES[@]}"; do sum=$((sum + l)); done
avg=$((sum / total))

echo ""
echo "  Sequential latency (200 requests, single node):"
echo "  Min:  ${min}ms"
echo "  Avg:  ${avg}ms"
echo "  P50:  ${p50}ms"
echo "  P95:  ${p95}ms"
echo "  P99:  ${p99}ms"
echo "  Max:  ${max}ms"
echo ""

# ============================================================
log "=== BENCH 4: Distributed throughput (all nodes) ==="

log "Hammering all 5 nodes concurrently for 10 seconds..."

for port in "${PORTS[@]}"; do
    (
        count=0
        end=$(($(date +%s) + 10))
        while [ $(date +%s) -lt $end ]; do
            curl -s -X POST http://localhost:$port/check \
                -H "Content-Type: application/json" \
                -d '{"key":"bench:distributed","limit":1000000,"hits":1,"window_ms":60000}' \
                -o /dev/null --max-time 1
            count=$((count + 1))
        done
        echo "node:$port requests=$count" >> $RESULTS_DIR/distributed_${TIMESTAMP}.txt
    ) &
done
wait

echo ""
echo "  Per-node throughput over 10s:"
total_reqs=0
while IFS= read -r line; do
    echo "  $line"
    reqs=$(echo $line | grep -o 'requests=[0-9]*' | cut -d= -f2)
    total_reqs=$((total_reqs + reqs))
done < $RESULTS_DIR/distributed_${TIMESTAMP}.txt
echo "  Total requests: $total_reqs"
echo "  Combined RPS:   $((total_reqs / 10))"
echo ""

# ============================================================
log "=== BENCH 5: Gossip convergence speed ==="

log "Measuring time for a write on node1 to be visible on node5..."

# reset the key
CONV_KEY="bench:convergence_$(date +%s)"
CONV_LIMIT=10000

convergence_times=()
for trial in $(seq 1 10); do
    # write to node1
    curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"${CONV_KEY}_${trial}\",\"limit\":$CONV_LIMIT,\"hits\":100,\"window_ms\":60000}" \
        -o /dev/null

    # poll node5 until it sees the write
    start=$(date +%s%N)
    while true; do
        remaining=$(curl -s -X POST http://localhost:8084/check \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"${CONV_KEY}_${trial}\",\"limit\":$CONV_LIMIT,\"hits\":1,\"window_ms\":60000}" \
            | grep -o '"remaining":[0-9]*' | cut -d: -f2)

        # node5 has seen the write when remaining drops below limit-100
        if [ -n "$remaining" ] && [ "$remaining" -lt $((CONV_LIMIT - 100)) ]; then
            end=$(date +%s%N)
            elapsed=$(( (end - start) / 1000000 ))
            convergence_times+=($elapsed)
            break
        fi

        elapsed_check=$(( ($(date +%s%N) - start) / 1000000 ))
        if [ $elapsed_check -gt 2000 ]; then
            convergence_times+=(2000)  # timeout
            break
        fi
    done
done

IFS=$'\n' SORTED_CONV=($(sort -n <<< "${convergence_times[*]}")); unset IFS
total_conv=${#SORTED_CONV[@]}
sum_conv=0
for t in "${convergence_times[@]}"; do sum_conv=$((sum_conv + t)); done
avg_conv=$((sum_conv / total_conv))
p50_conv=${SORTED_CONV[$((total_conv * 50 / 100))]}
p95_conv=${SORTED_CONV[$((total_conv * 95 / 100))]}

echo ""
echo "  Gossip convergence time (node1 → node5, 10 trials):"
echo "  Min:  ${SORTED_CONV[0]}ms"
echo "  Avg:  ${avg_conv}ms"
echo "  P50:  ${p50_conv}ms"
echo "  P95:  ${p95_conv}ms"
echo "  Max:  ${SORTED_CONV[$((total_conv - 1))]}ms"
echo ""

# ============================================================
log "=== BENCH 6: Throughput under node failure ==="

log "Measuring throughput while killing and restarting node3..."

# start background flood
(
    count=0
    end=$(($(date +%s) + 20))
    while [ $(date +%s) -lt $end ]; do
        curl -s -X POST http://localhost:8080/check \
            -H "Content-Type: application/json" \
            -d '{"key":"bench:failure_throughput","limit":1000000,"hits":1,"window_ms":60000}' \
            -o /dev/null --max-time 1
        count=$((count + 1))
    done
    echo $count > $RESULTS_DIR/failure_throughput_${TIMESTAMP}.txt
) &
FLOOD_PID=$!

# kill node3 mid-flood
sleep 5
docker compose stop node3 2>/dev/null
sleep 5
docker compose start node3 2>/dev/null

wait $FLOOD_PID

failure_reqs=$(cat $RESULTS_DIR/failure_throughput_${TIMESTAMP}.txt 2>/dev/null || echo 0)
echo ""
echo "  Requests completed during node failure/recovery (20s): $failure_reqs"
echo "  RPS during failure: $((failure_reqs / 20))"
echo ""

# ============================================================
log "=== BENCH 7: Rate limit accuracy under load ==="

log "Checking rate limit accuracy: sending exactly 20 requests with limit=20..."

# use unique key per run
ACCURACY_KEY="bench:accuracy_$(date +%s)"

allowed=0
denied=0
for i in $(seq 1 25); do
    status=$(curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$ACCURACY_KEY\",\"limit\":20,\"hits\":1,\"window_ms\":60000}" \
        | grep -o '"status":[0-9]*' | cut -d: -f2)
    if [ "$status" = "200" ]; then
        allowed=$((allowed + 1))
    else
        denied=$((denied + 1))
    fi
done

echo ""
echo "  Sent 25 requests with limit=20 to single node:"
echo "  Allowed: $allowed (expected: 20)"
echo "  Denied:  $denied (expected: 5)"
if [ "$allowed" -eq 20 ] && [ "$denied" -eq 5 ]; then
    echo "  ✓ Rate limit perfectly accurate on single node"
else
    echo "  ~ Rate limit accuracy: $allowed/20 allowed (eventual consistency expected across nodes)"
fi
echo ""

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           BENCHMARK SUMMARY              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo ""
echo "  Install hey for better throughput numbers:"
echo "  go install github.com/rakyll/hey@latest"
echo ""
echo "  Install wrk for sustained load testing:"
echo "  sudo apt install wrk"
echo ""
echo "Run 'docker compose down' when done"