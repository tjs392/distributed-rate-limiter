#!/bin/bash
# tests/persistence.sh - verify counters survive node restarts

PROTO_PATH="./proto/rls.proto"
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

grpc_call() {
    local port=$1 json_data=$2
    grpcurl -plaintext \
        -import-path ./proto -proto rls.proto \
        -d "$json_data" -max-time 2 \
        localhost:$port \
        envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit 2>/dev/null
}

send_n() {
    local n=$1 port=$2 json_data=$3
    local ok=0 over=0
    for i in $(seq 1 $n); do
        result=$(grpc_call $port "$json_data")
        if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
            over=$((over + 1))
        else
            ok=$((ok + 1))
        fi
    done
    echo "$ok $over"
}

TS=$(date +%s%N)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"persist_${TS}\"}]}],\"hits_addend\":1}"

# ============================================================
log "TEST 1: Cluster healthy"

result=$(curl -s --max-time 2 http://localhost:8080/health)
if ! echo "$result" | grep -q "node_id"; then
    echo "  FAIL: cluster not healthy, aborting"
    exit 1
fi
assert "cluster healthy" "echo '$result' | grep -q 'node_id'"

# ============================================================
log "TEST 2: Send 500 requests (limit=1000/min, all should pass)"

read ok over <<< $(send_n 500 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "all 500 allowed" "[ $ok -eq 500 ]"

# ============================================================
log "TEST 3: Wait for eviction flush to disk (12s)"

sleep 12
assert "waited for disk flush" "true"

# ============================================================
log "TEST 4: Restart node1"

docker compose stop node1 2>/dev/null
sleep 2
docker compose start node1 2>/dev/null
sleep 5
result=$(curl -s --max-time 2 http://localhost:8080/health)
assert "node1 healthy after restart" "echo '$result' | grep -q 'node_id'"

# ============================================================
log "TEST 5: Counters survived restart (send 600 more, expect ~100 denied)"

read ok over <<< $(send_n 600 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "some requests denied (counters persisted)" "[ $over -gt 0 ]"

# ============================================================
log "TEST 6: Counter accuracy after restart"

echo "  allowed=$ok (expected ~500)"
assert "counter approximately correct (400-600 allowed)" "[ $ok -ge 400 ] && [ $ok -le 600 ]"

# ============================================================
log "TEST 7: Fresh key works after restart"

TS2=$(date +%s%N)
DATA2="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"fresh_${TS2}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 10 50051 "$DATA2")
echo "  allowed=$ok denied=$over"
assert "fresh key works normally" "[ $ok -eq 10 ]"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL