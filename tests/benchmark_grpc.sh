#!/bin/bash
# benchmark_grpc.sh
# Benchmarks the gRPC RateLimitService interface

RESULTS_DIR="./benchmark_results/grpc"
mkdir -p $RESULTS_DIR
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PROTO_PATH="./proto/rls.proto"
GRPC_PORTS=(50051 50052 50053 50054 50055)

log() { echo "[$(date '+%H:%M:%S')] $1"; }

extract_rps()  { grep "Requests/sec:" $1 | awk '{print $2}'; }
extract_avg()  { grep "Average:" $1 | awk '{print $2, $3}'; }
extract_fast() { grep "Fastest:" $1 | awk '{print $2, $3}'; }
extract_slow() { grep "Slowest:" $1 | awk '{print $2, $3}'; }
extract_p50()  { grep "50 %" $1 | awk '{print $4, $5}'; }
extract_p95()  { grep "95 %" $1 | awk '{print $4, $5}'; }
extract_p99()  { grep "99 %" $1 | awk '{print $4, $5}'; }
extract_status() { grep -A1 "Status code" $1 | grep -v "Status code"; }

print_summary() {
    local file=$1
    echo "  Requests/sec: $(extract_rps $file)"
    echo "  Fastest:      $(extract_fast $file)"
    echo "  Average:      $(extract_avg $file)"
    echo "  Slowest:      $(extract_slow $file)"
    echo "  P50:          $(extract_p50 $file)"
    echo "  P95:          $(extract_p95 $file)"
    echo "  P99:          $(extract_p99 $file)"
    echo "  Status:       $(extract_status $file)"
}

check_deps() {
    if ! command -v ghz &> /dev/null; then
        echo ""
        echo "ghz not installed. Install it:"
        echo "  go install github.com/bojand/ghz/cmd/ghz@latest"
        echo ""
        exit 1
    fi
    if ! command -v hey &> /dev/null; then
        echo "hey not installed — bench 5 HTTP comparison will be skipped"
        echo "  go install github.com/rakyll/hey@latest"
    fi
}

ghz_run() {
    local output=$1
    local port=$2
    local data=$3
    shift 3
    ghz \
        --insecure \
        --proto $PROTO_PATH \
        --call envoy.service.ratelimit.v3.RateLimitService.ShouldRateLimit \
        --data "$data" \
        --timeout 2s \
        "$@" \
        localhost:$port > $output 2>&1
}

check_deps

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     gRPC Rate Limiter Benchmark (ghz)    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

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
log "=== BENCH 1: Single node baseline (10,000 requests, c=50) ==="

OUT=$RESULTS_DIR/bench1_baseline_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --total 10000 --concurrency 50

echo ""
print_summary $OUT
echo ""

# ============================================================
log "=== BENCH 2: Sustained load (30s, c=100) ==="

OUT=$RESULTS_DIR/bench2_sustained_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --duration 30s --concurrency 100

echo ""
print_summary $OUT
echo ""

# ============================================================
log "=== BENCH 3: Latency at different concurrency levels ==="

echo ""
printf "  %-12s %-16s %-12s %-12s %-12s\n" "Concurrency" "RPS" "Avg" "P95" "P99"
printf "  %-12s %-16s %-12s %-12s %-12s\n" "-----------" "---" "---" "---" "---"

for concurrency in 1 10 50 100 200; do
    OUT=/tmp/ghz_c${concurrency}_${TIMESTAMP}.txt
    ghz_run $OUT 50051 "$SINGLE_DESCRIPTOR" --total 5000 --concurrency $concurrency

    rps=$(extract_rps $OUT)
    avg=$(extract_avg $OUT)
    p95=$(extract_p95 $OUT)
    p99=$(extract_p99 $OUT)
    printf "  %-12s %-16s %-12s %-12s %-12s\n" "$concurrency" "$rps" "$avg" "$p95" "$p99"
done
echo ""

# ============================================================
log "=== BENCH 4: Multi-descriptor request (realistic Envoy workload) ==="

OUT=$RESULTS_DIR/bench4_multi_descriptor_${TIMESTAMP}.txt
ghz_run $OUT 50051 "$MULTI_DESCRIPTOR" --total 10000 --concurrency 50

echo ""
print_summary $OUT
echo ""

# ============================================================
log "=== BENCH 5: gRPC vs HTTP ==="

GRPC_OUT=/tmp/ghz_compare_${TIMESTAMP}.txt
ghz_run $GRPC_OUT 50051 "$SINGLE_DESCRIPTOR" --total 10000 --concurrency 50

grpc_rps=$(extract_rps $GRPC_OUT)
grpc_avg=$(extract_avg $GRPC_OUT)
grpc_p99=$(extract_p99 $GRPC_OUT)

if command -v hey &> /dev/null; then
    HTTP_OUT=/tmp/hey_compare_${TIMESTAMP}.txt
    hey -n 10000 -c 50 -m POST \
        -H "Content-Type: application/json" \
        -d '{"key":"compare:user_id:bench_user","limit":100000,"hits":1,"window_ms":60000}' \
        http://localhost:8080/check > $HTTP_OUT 2>&1

    http_rps=$(grep "Requests/sec" $HTTP_OUT | awk '{print $2}')
    http_avg=$(grep "Average" $HTTP_OUT | awk '{print $2, $3}')
    http_p99=$(grep "99%" $HTTP_OUT | awk '{print $2}')
else
    http_rps="(hey not installed)"
    http_avg="-"
    http_p99="-"
fi

echo ""
echo "  ┌─────────────┬──────────────────┬──────────────┬──────────────┐"
echo "  │ Interface   │ RPS              │ Avg          │ P99          │"
echo "  ├─────────────┼──────────────────┼──────────────┼──────────────┤"
printf "  │ gRPC        │ %-16s │ %-12s │ %-12s │\n" "$grpc_rps" "$grpc_avg" "$grpc_p99"
printf "  │ HTTP        │ %-16s │ %-12s │ %-12s │\n" "$http_rps" "$http_avg" "$http_p99"
echo "  └─────────────┴──────────────────┴──────────────┴──────────────┘"
echo ""

# ============================================================
log "=== BENCH 6: Distributed throughput (all 5 nodes, 15s) ==="

echo ""
for port in "${GRPC_PORTS[@]}"; do
    OUT=/tmp/ghz_dist_${port}_${TIMESTAMP}.txt
    ghz_run $OUT $port "$SINGLE_DESCRIPTOR" --duration 15s --concurrency 50 &
done
wait

total_rps=0
printf "  %-10s %-16s %-12s %-12s\n" "Node" "RPS" "Avg" "P99"
printf "  %-10s %-16s %-12s %-12s\n" "----" "---" "---" "---"
for port in "${GRPC_PORTS[@]}"; do
    OUT=/tmp/ghz_dist_${port}_${TIMESTAMP}.txt
    rps=$(extract_rps $OUT)
    avg=$(extract_avg $OUT)
    p99=$(extract_p99 $OUT)
    printf "  %-10s %-16s %-12s %-12s\n" ":$port" "$rps" "$avg" "$p99"
    total_rps=$(echo "$total_rps + ${rps%.*}" | bc 2>/dev/null || echo $total_rps)
done
echo "  Combined RPS: ~$total_rps"
echo ""

# ============================================================
log "=== BENCH 7: Throughput under node failure ==="
log "Running 25s load while killing and restarting node3..."

FAILURE_OUT=$RESULTS_DIR/bench7_failure_${TIMESTAMP}.txt
ghz_run $FAILURE_OUT 50051 "$SINGLE_DESCRIPTOR" --duration 25s --concurrency 50 &
GHZ_PID=$!

sleep 5
log "  Killing node3..."
docker compose stop node3 2>/dev/null
sleep 8
log "  Restarting node3..."
docker compose start node3 2>/dev/null
wait $GHZ_PID

echo ""
print_summary $FAILURE_OUT
echo ""

# ============================================================
log "=== BENCH 8: Single node vs multi-descriptor overhead ==="

SINGLE_OUT=/tmp/ghz_single_desc_${TIMESTAMP}.txt
MULTI_OUT=/tmp/ghz_multi_desc_${TIMESTAMP}.txt

ghz_run $SINGLE_OUT 50051 "$SINGLE_DESCRIPTOR" --total 5000 --concurrency 50
ghz_run $MULTI_OUT 50051 "$MULTI_DESCRIPTOR" --total 5000 --concurrency 50

single_rps=$(extract_rps $SINGLE_OUT)
single_avg=$(extract_avg $SINGLE_OUT)
multi_rps=$(extract_rps $MULTI_OUT)
multi_avg=$(extract_avg $MULTI_OUT)

echo ""
echo "  ┌──────────────────────┬──────────────────┬──────────────┐"
echo "  │ Request type         │ RPS              │ Avg          │"
echo "  ├──────────────────────┼──────────────────┼──────────────┤"
printf "  │ Single descriptor   │ %-16s │ %-12s │\n" "$single_rps" "$single_avg"
printf "  │ Multi descriptor    │ %-16s │ %-12s │\n" "$multi_rps" "$multi_avg"
echo "  └──────────────────────┴──────────────────┴──────────────┘"
echo ""

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           gRPC BENCHMARK SUMMARY         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Full results saved to: $RESULTS_DIR/"
echo ""
echo "  View a result:"
echo "  cat $RESULTS_DIR/bench1_baseline_${TIMESTAMP}.txt"
echo ""
echo "Run 'docker compose down' when done"