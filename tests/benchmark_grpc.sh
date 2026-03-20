#!/bin/bash
# benchmark_grpc.sh - gRPC throughput and latency benchmarks

RESULTS_DIR="./benchmark_results/grpc"
mkdir -p $RESULTS_DIR
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PROTO_PATH="./proto/rls.proto"
GRPC_PORTS=(50051 50052 50053 50054 50055)
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

extract_rps()  { grep "Requests/sec:" $1 | awk '{print $2}'; }
extract_avg()  { grep "Average:" $1 | awk '{print $2, $3}'; }
extract_p50()  { grep "50 %" $1 | awk '{print $4, $5}'; }
extract_p95()  { grep "95 %" $1 | awk '{print $4, $5}'; }
extract_p99()  { grep "99 %" $1 | awk '{print $4, $5}'; }

ghz_run() {
    local output=$1 port=$2 data=$3
    shift 3
    ghz --insecure --proto $PROTO_PATH \
        --call envoy.service.ratelimit.v3.RateLimitService.ShouldRateLimit \
        --data "$data" --timeout 2s "$@" localhost:$port > $output 2>&1
}

if ! command -v ghz &> /dev/null; then
    echo "ghz not installed (go install github.com/bojand/ghz/cmd/ghz@latest)"
    exit 1
fi

SINGLE_DESCRIPTOR='{
    "domain": "benchmark",
    "descriptors": [{"entries": [{"key": "user_id", "value": "bench_user"}]}],
    "hits_addend": 1
}'

MULTI_DESCRIPTOR='{
    "domain": "my_app",
    "descriptors": [
        {"entries": [{"key": "user_id", "value": "user_123"}]},
        {"entries": [{"key": "tier", "value": "premium"}, {"key": "user_id", "value": "user_123"}]},
        {"entries": [{"key": "path", "value": "/api/search"}]}
    ],
    "hits_addend": 1
}'

# ============================================================
log "BENCH 1: Single node baseline (10k requests, c=50)"

OUT=$RESULTS_DIR/bench1_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --total 10000 --concurrency 50

RPS=$(extract_rps $OUT | awk '{printf "%d", $1}')
echo "  RPS: $(extract_rps $OUT)  Avg: $(extract_avg $OUT)  P99: $(extract_p99 $OUT)"
assert "grpc throughput > 5000 rps" "[ $RPS -gt 5000 ]"

# ============================================================
log "BENCH 2: Sustained load (30s, c=100)"

OUT=$RESULTS_DIR/bench2_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --duration 30s --concurrency 100

RPS=$(extract_rps $OUT | awk '{printf "%d", $1}')
echo "  RPS: $(extract_rps $OUT)  Avg: $(extract_avg $OUT)  P99: $(extract_p99 $OUT)"
assert "sustained throughput > 5000 rps" "[ $RPS -gt 5000 ]"

# ============================================================
log "BENCH 3: Latency at different concurrency levels"

printf "  %-12s %-16s %-12s %-12s %-12s\n" "Concurrency" "RPS" "Avg" "P95" "P99"
for concurrency in 1 10 50 100 200; do
    OUT=/tmp/ghz_c${concurrency}_${TIMESTAMP}.txt
    ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --total 5000 --concurrency $concurrency
    printf "  %-12s %-16s %-12s %-12s %-12s\n" \
        "$concurrency" "$(extract_rps $OUT)" "$(extract_avg $OUT)" "$(extract_p95 $OUT)" "$(extract_p99 $OUT)"
done

# ============================================================
log "BENCH 4: Multi-descriptor request (10k, c=50)"

OUT=$RESULTS_DIR/bench4_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$MULTI_DESCRIPTOR" --total 10000 --concurrency 50

RPS=$(extract_rps $OUT | awk '{printf "%d", $1}')
echo "  RPS: $(extract_rps $OUT)  Avg: $(extract_avg $OUT)  P99: $(extract_p99 $OUT)"
assert "multi-descriptor throughput > 2000 rps" "[ $RPS -gt 2000 ]"

# ============================================================
log "BENCH 5: gRPC vs HTTP comparison"

GRPC_OUT=/tmp/ghz_compare_${TIMESTAMP}.txt
ghz_run $GRPC_OUT 50051 "$SINGLE_DESCRIPTOR" --total 10000 --concurrency 50
grpc_rps=$(extract_rps $GRPC_OUT)
grpc_avg=$(extract_avg $GRPC_OUT)
grpc_p99=$(extract_p99 $GRPC_OUT)

if command -v hey &> /dev/null; then
    HTTP_OUT=/tmp/hey_compare_${TIMESTAMP}.txt
    hey -n 10000 -c 50 -m POST \
        -H "Content-Type: application/json" \
        -d '{"key":"compare:bench","limit":100000,"hits":1,"window_ms":60000}' \
        http://localhost:8080/check > $HTTP_OUT 2>&1
    http_rps=$(grep "Requests/sec" $HTTP_OUT | awk '{print $2}')
    http_avg=$(grep "Average" $HTTP_OUT | awk '{print $2, $3}')
    http_p99=$(grep "99%" $HTTP_OUT | awk '{print $2}')
else
    http_rps="n/a" http_avg="n/a" http_p99="n/a"
fi

printf "  %-8s %-16s %-12s %-12s\n" "" "RPS" "Avg" "P99"
printf "  %-8s %-16s %-12s %-12s\n" "gRPC" "$grpc_rps" "$grpc_avg" "$grpc_p99"
printf "  %-8s %-16s %-12s %-12s\n" "HTTP" "$http_rps" "$http_avg" "$http_p99"

# ============================================================
log "BENCH 6: Distributed throughput (all 5 nodes, 15s)"

for port in "${GRPC_PORTS[@]}"; do
    OUT=/tmp/ghz_dist_${port}_${TIMESTAMP}.txt
    ghz_run $OUT $port "$SINGLE_DESCRIPTOR" --duration 15s --concurrency 50 &
done
wait

total_rps=0
printf "  %-10s %-16s %-12s %-12s\n" "Node" "RPS" "Avg" "P99"
for port in "${GRPC_PORTS[@]}"; do
    OUT=/tmp/ghz_dist_${port}_${TIMESTAMP}.txt
    rps=$(extract_rps $OUT)
    printf "  %-10s %-16s %-12s %-12s\n" ":$port" "$rps" "$(extract_avg $OUT)" "$(extract_p99 $OUT)"
    total_rps=$(echo "$total_rps + ${rps%.*}" | bc 2>/dev/null || echo $total_rps)
done
echo "  Combined RPS: ~$total_rps"
assert "cluster grpc throughput > 10000 rps" "[ ${total_rps%.*} -gt 10000 ]"

# ============================================================
log "BENCH 7: Throughput under node failure (25s)"

OUT=$RESULTS_DIR/bench7_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --duration 25s --concurrency 50 &
GHZ_PID=$!

sleep 5
log "  Killing node3..."
docker compose stop node3 2>/dev/null
sleep 8
log "  Restarting node3..."
docker compose start node3 2>/dev/null
wait $GHZ_PID

RPS=$(extract_rps $OUT | awk '{printf "%d", $1}')
echo "  RPS: $(extract_rps $OUT)  Avg: $(extract_avg $OUT)  P99: $(extract_p99 $OUT)"
assert "maintained throughput during failure" "[ $RPS -gt 1000 ]"

# ============================================================
log "BENCH 8: Single vs multi-descriptor overhead"

SINGLE_OUT=/tmp/ghz_single_${TIMESTAMP}.txt
MULTI_OUT=/tmp/ghz_multi_${TIMESTAMP}.txt
ghz_run $SINGLE_OUT 50051 "$SINGLE_DESCRIPTOR" --total 5000 --concurrency 50
ghz_run $MULTI_OUT 50051 "$MULTI_DESCRIPTOR" --total 5000 --concurrency 50

printf "  %-22s %-16s %-12s\n" "" "RPS" "Avg"
printf "  %-22s %-16s %-12s\n" "Single descriptor" "$(extract_rps $SINGLE_OUT)" "$(extract_avg $SINGLE_OUT)"
printf "  %-22s %-16s %-12s\n" "Multi descriptor" "$(extract_rps $MULTI_OUT)" "$(extract_avg $MULTI_OUT)"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Saved to: $RESULTS_DIR/"
exit $FAIL