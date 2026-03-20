#!/bin/bash
# tests/stress.sh - heavy load stress test across HTTP and gRPC

ENVOY="http://localhost:10000"
PROTO_PATH="./proto/rls.proto"
GRPC_METHOD="envoy.service.ratelimit.v3.RateLimitService.ShouldRateLimit"
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

unique_key() { echo "stress_$(date +%s%N)_${RANDOM}"; }

parse_hey_status() {
    local output="$1" code=$2
    echo "$output" | grep "\[$code\]" | awk '{print $2}' || echo "0"
}

parse_hey_rps() {
    echo "$1" | grep "Requests/sec" | awk '{printf "%d", $2}'
}

check_deps() {
    local missing=false
    command -v hey &>/dev/null || { echo "missing: hey"; missing=true; }
    command -v ghz &>/dev/null || { echo "missing: ghz"; missing=true; }
    command -v grpcurl &>/dev/null || { echo "missing: grpcurl"; missing=true; }
    $missing && exit 1
}

restart_cluster() {
    log "Restarting cluster for clean state..."
    docker compose down --timeout 2 2>/dev/null
    docker compose up -d 2>/dev/null
    for i in $(seq 1 15); do
        if curl -s --max-time 1 http://localhost:8080/health | grep -q "node_id"; then
            return
        fi
        sleep 1
    done
    echo "  WARNING: cluster not ready after 15s"
}

check_deps

# ============================================================
log "Checking services"

curl -s --max-time 2 http://localhost:8080/health -o /dev/null || { echo "Rate limiter not responding"; exit 1; }
echo "  Services healthy"

START=$(date +%s)

# ============================================================
log "STRESS 1: HTTP throughput (100k requests, c=200)"

OUT=$(hey -n 100000 -c 200 -m POST \
    -H "Content-Type: application/json" \
    -d '{"key":"stress:http","limit":10000000,"hits":1,"window_ms":60000}' \
    http://localhost:8080/check 2>&1)

HTTP_RPS=$(parse_hey_rps "$OUT")
echo "  RPS: $HTTP_RPS"
echo "$OUT" | grep -E "Requests/sec|Average|Slowest" | sed 's/^/  /'
assert "HTTP throughput > 20000 rps" "[ $HTTP_RPS -gt 20000 ]"

# ============================================================
log "STRESS 2: gRPC throughput (100k requests, c=200)"

TS=$(unique_key)
ghz --insecure --proto $PROTO_PATH --call $GRPC_METHOD \
    -d "{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
    --total 100000 --concurrency 200 \
    localhost:50051 > /tmp/stress_grpc.txt 2>&1

GRPC_RPS=$(grep "Requests/sec:" /tmp/stress_grpc.txt | awk '{printf "%d", $2}')
echo "  RPS: $GRPC_RPS"
grep -E "Requests/sec|Average|Slowest|50th|99th" /tmp/stress_grpc.txt | sed 's/^/  /'
assert "gRPC throughput > 10000 rps" "[ $GRPC_RPS -gt 10000 ]"

# ============================================================
log "STRESS 3: HTTP accuracy under concurrency (limit=600, c=100, n=2000)"

restart_cluster

OUT=$(hey -n 2000 -c 100 -m POST \
    -H "Content-Type: application/json" \
    -d '{"key":"stress:accuracy","limit":600,"hits":1,"window_ms":60000}' \
    http://localhost:8080/check 2>&1)

ok=$(parse_hey_status "$OUT" 200)
denied=$(parse_hey_status "$OUT" 429)
ok=${ok:-0}
denied=${denied:-0}
total=$((ok + denied))
echo "  allowed=$ok denied=$denied (limit=600)"
assert "all 2000 requests got responses" "[ $total -eq 2000 ]"
assert "some requests allowed" "[ $ok -gt 0 ]"

# ============================================================
log "STRESS 4: gRPC accuracy under concurrency (limit=1000/min, c=100, n=1500)"

TS=$(unique_key)
ghz --insecure --proto $PROTO_PATH --call $GRPC_METHOD \
    -d "{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
    --total 1500 --concurrency 100 \
    localhost:50051 > /tmp/stress_grpc_acc.txt 2>&1

grpc_ok=$(grep "\[OK\]" /tmp/stress_grpc_acc.txt | awk '{print $2}' || echo 0)
echo "  allowed=$grpc_ok (limit=1000)"
grep -E "Count:|OK|OverLimit" /tmp/stress_grpc_acc.txt | sed 's/^/  /'

# ============================================================
log "STRESS 5: Distributed gRPC (all 5 nodes, 15s each, c=100)"

restart_cluster

TS=$(unique_key)
DATA="{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}"

for port in "${GRPC_PORTS[@]}"; do
    ghz --insecure --proto $PROTO_PATH --call $GRPC_METHOD \
        -d "$DATA" --duration 15s --concurrency 100 \
        localhost:$port > /tmp/stress_dist_${port}.txt 2>&1 &
done
wait

total_rps=0
printf "  %-10s %-12s %-12s %-12s\n" "Node" "RPS" "Avg" "P99"
for port in "${GRPC_PORTS[@]}"; do
    rps=$(grep "Requests/sec:" /tmp/stress_dist_${port}.txt | awk '{printf "%d", $2}')
    avg=$(grep "Average:" /tmp/stress_dist_${port}.txt | awk '{print $2, $3}')
    p99=$(grep "99th" /tmp/stress_dist_${port}.txt | awk '{print $3, $4}')
    printf "  %-10s %-12s %-12s %-12s\n" ":$port" "$rps" "$avg" "$p99"
    total_rps=$((total_rps + rps))
done
echo "  Combined RPS: $total_rps"
assert "cluster gRPC throughput > 50000 rps" "[ $total_rps -gt 50000 ]"

# ============================================================
log "STRESS 6: HTTP latency under increasing concurrency"

printf "  %-12s %-12s %-12s %-12s\n" "Concurrency" "RPS" "Avg" "P99"
for conc in 10 50 100 200 500; do
    OUT=$(hey -n 10000 -c $conc -m POST \
        -H "Content-Type: application/json" \
        -d '{"key":"stress:latency","limit":10000000,"hits":1,"window_ms":60000}' \
        http://localhost:8080/check 2>&1)
    rps=$(parse_hey_rps "$OUT")
    avg=$(echo "$OUT" | grep "Average" | awk '{print $2}')
    p99=$(echo "$OUT" | grep "99%" | awk '{print $4}')
    printf "  %-12s %-12s %-12s %-12s\n" "$conc" "$rps" "$avg" "$p99"
done

# ============================================================
log "STRESS 7: gRPC latency under increasing concurrency"

printf "  %-12s %-12s %-12s %-12s\n" "Concurrency" "RPS" "Avg" "P99"
for conc in 10 50 100 200 500; do
    TS=$(unique_key)
    ghz --insecure --proto $PROTO_PATH --call $GRPC_METHOD \
        -d "{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
        --total 10000 --concurrency $conc \
        localhost:50051 > /tmp/stress_lat_${conc}.txt 2>&1
    rps=$(grep "Requests/sec:" /tmp/stress_lat_${conc}.txt | awk '{printf "%d", $2}')
    avg=$(grep "Average:" /tmp/stress_lat_${conc}.txt | awk '{print $2, $3}')
    p99=$(grep "99th" /tmp/stress_lat_${conc}.txt | awk '{print $3, $4}')
    printf "  %-12s %-12s %-12s %-12s\n" "$conc" "$rps" "$avg" "$p99"
done

# ============================================================
log "STRESS 8: Throughput during node failure (25s)"

OUT_FILE=/tmp/stress_failure.txt
hey -n 0 -c 100 -z 25s -m POST \
    -H "Content-Type: application/json" \
    -d '{"key":"stress:failure","limit":10000000,"hits":1,"window_ms":60000}' \
    http://localhost:8080/check > $OUT_FILE 2>&1 &
HEY_PID=$!

sleep 5
log "  Killing node3..."
docker compose stop node3 2>/dev/null
sleep 8
log "  Restarting node3..."
docker compose start node3 2>/dev/null
wait $HEY_PID

FAIL_RPS=$(parse_hey_rps "$(cat $OUT_FILE)")
echo "  RPS during failure: $FAIL_RPS"
grep -E "Requests/sec|Average|Slowest" $OUT_FILE | sed 's/^/  /'
assert "maintained throughput during failure" "[ $FAIL_RPS -gt 5000 ]"

# ============================================================
END=$(date +%s)
ELAPSED=$((END - START))

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total time: ${ELAPSED}s"
exit $FAIL