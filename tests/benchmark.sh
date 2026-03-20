#!/bin/bash
# benchmark.sh - HTTP throughput and latency benchmarks

PORTS=(8080 8081 8082 8083 8084)
RESULTS_DIR="./benchmark_results"
mkdir -p $RESULTS_DIR
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $1"; }

assert() {
    local desc=$1 cond=$2
    if eval "$cond"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
log "BENCH 1: Single node baseline (hey, 10k requests, c=50)"

if command -v hey &> /dev/null; then
    OUT=$RESULTS_DIR/hey_single_${TIMESTAMP}.txt
    hey -n 10000 -c 50 -m POST \
        -H "Content-Type: application/json" \
        -d '{"key":"bench:throughput","limit":100000,"hits":1,"window_ms":60000}' \
        http://localhost:8080/check > $OUT 2>&1

    RPS=$(grep "Requests/sec" $OUT | awk '{printf "%d", $2}')
    echo ""
    grep -E "Requests/sec|Average|Fastest|Slowest" $OUT | sed 's/^/  /'
    echo ""
    assert "throughput > 10000 rps" "[ $RPS -gt 10000 ]"
else
    log "hey not installed, skipping (go install github.com/rakyll/hey@latest)"
fi

# ============================================================
log "BENCH 2: Single node baseline (wrk, 10s, c=50)"

if command -v wrk &> /dev/null; then
    cat > /tmp/wrk_post.lua << 'EOF'
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"key":"bench:wrk","limit":100000,"hits":1,"window_ms":60000}'
EOF

    OUT=$RESULTS_DIR/wrk_single_${TIMESTAMP}.txt
    wrk -t4 -c50 -d10s -s /tmp/wrk_post.lua \
        http://localhost:8080/check > $OUT 2>&1

    echo ""
    cat $OUT | sed 's/^/  /'
    echo ""
else
    log "wrk not installed, skipping (sudo apt install wrk)"
fi

# ============================================================
log "BENCH 3: Sequential latency (200 requests)"

LATENCIES=()
for i in $(seq 1 200); do
    start=$(date +%s%N)
    curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d '{"key":"bench:latency","limit":100000,"hits":1,"window_ms":60000}' \
        -o /dev/null --max-time 2
    end=$(date +%s%N)
    LATENCIES+=( $(( (end - start) / 1000000 )) )
done

IFS=$'\n' SORTED=($(sort -n <<< "${LATENCIES[*]}")); unset IFS
total=${#SORTED[@]}
sum=0; for l in "${LATENCIES[@]}"; do sum=$((sum + l)); done

p50=${SORTED[$((total * 50 / 100))]}
p95=${SORTED[$((total * 95 / 100))]}
p99=${SORTED[$((total * 99 / 100))]}
avg=$((sum / total))

echo "  Min: ${SORTED[0]}ms  Avg: ${avg}ms  P50: ${p50}ms  P95: ${p95}ms  P99: ${p99}ms  Max: ${SORTED[$((total-1))]}ms"
assert "p50 latency < 50ms" "[ $p50 -lt 50 ]"
assert "p99 latency < 200ms" "[ $p99 -lt 200 ]"

# ============================================================
log "BENCH 4: Distributed throughput (all 5 nodes, 10s)"

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

total_reqs=0
while IFS= read -r line; do
    echo "  $line"
    reqs=$(echo $line | grep -o 'requests=[0-9]*' | cut -d= -f2)
    total_reqs=$((total_reqs + reqs))
done < $RESULTS_DIR/distributed_${TIMESTAMP}.txt
echo "  Total: $total_reqs  Combined RPS: $((total_reqs / 10))"
assert "combined cluster RPS > 500" "[ $((total_reqs / 10)) -gt 500 ]"

# ============================================================
log "BENCH 5: Gossip convergence (node1 -> node5, 10 trials)"

convergence_times=()
for trial in $(seq 1 10); do
    CONV_KEY="bench:conv_${TIMESTAMP}_${trial}"
    curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$CONV_KEY\",\"limit\":10000,\"hits\":100,\"window_ms\":60000}" \
        -o /dev/null

    start=$(date +%s%N)
    while true; do
        remaining=$(curl -s -X POST http://localhost:8084/check \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"$CONV_KEY\",\"limit\":10000,\"hits\":1,\"window_ms\":60000}" \
            | grep -o '"remaining":[0-9]*' | cut -d: -f2)

        if [ -n "$remaining" ] && [ "$remaining" -lt 9900 ]; then
            convergence_times+=( $(( ($(date +%s%N) - start) / 1000000 )) )
            break
        fi
        if [ $(( ($(date +%s%N) - start) / 1000000 )) -gt 2000 ]; then
            convergence_times+=(2000)
            break
        fi
    done
done

IFS=$'\n' SORTED_CONV=($(sort -n <<< "${convergence_times[*]}")); unset IFS
sum_conv=0; for t in "${convergence_times[@]}"; do sum_conv=$((sum_conv + t)); done
avg_conv=$((sum_conv / ${#SORTED_CONV[@]}))
p50_conv=${SORTED_CONV[$((${#SORTED_CONV[@]} * 50 / 100))]}

echo "  Min: ${SORTED_CONV[0]}ms  Avg: ${avg_conv}ms  P50: ${p50_conv}ms  Max: ${SORTED_CONV[$((${#SORTED_CONV[@]}-1))]}ms"
assert "gossip convergence p50 < 500ms" "[ $p50_conv -lt 500 ]"

# ============================================================
log "BENCH 6: Throughput under node failure (20s)"

(
    count=0
    end=$(($(date +%s) + 20))
    while [ $(date +%s) -lt $end ]; do
        curl -s -X POST http://localhost:8080/check \
            -H "Content-Type: application/json" \
            -d '{"key":"bench:failure","limit":1000000,"hits":1,"window_ms":60000}' \
            -o /dev/null --max-time 1
        count=$((count + 1))
    done
    echo $count > /tmp/failure_reqs_${TIMESTAMP}.txt
) &
FLOOD_PID=$!

sleep 5
docker compose stop node3 2>/dev/null
sleep 5
docker compose start node3 2>/dev/null
wait $FLOOD_PID

failure_reqs=$(cat /tmp/failure_reqs_${TIMESTAMP}.txt 2>/dev/null || echo 0)
echo "  Requests during failure/recovery: $failure_reqs  RPS: $((failure_reqs / 20))"
assert "maintained throughput during failure" "[ $failure_reqs -gt 100 ]"

# ============================================================
log "BENCH 7: Rate limit accuracy (25 requests, limit=20)"

ACCURACY_KEY="bench:accuracy_$(date +%s)"
allowed=0
denied=0
for i in $(seq 1 25); do
    status=$(curl -s -X POST http://localhost:8080/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$ACCURACY_KEY\",\"limit\":20,\"hits\":1,\"window_ms\":60000}" \
        | grep -o '"status":[0-9]*' | cut -d: -f2)
    if [ "$status" = "200" ]; then allowed=$((allowed + 1)); else denied=$((denied + 1)); fi
done

echo "  Allowed: $allowed/20  Denied: $denied/5"
assert "allowed exactly 20" "[ $allowed -eq 20 ]"
assert "denied exactly 5" "[ $denied -eq 5 ]"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Saved to: $RESULTS_DIR/"
exit $FAIL