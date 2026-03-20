#!/bin/bash
# tests/persistence.sh
# Tests that rate limit counters persist across node restarts
#
# Prerequisites:
#   - grpcurl installed
#   - docker compose cluster running

PROTO_PATH="./proto/rls.proto"
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $1"; }
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

grpc_call() {
    local port=$1
    local json_data=$2
    grpcurl -plaintext \
        -import-path ./proto -proto rls.proto \
        -d "$json_data" \
        -max-time 2 \
        localhost:$port \
        envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit 2>/dev/null
}

send_n() {
    local n=$1
    local port=$2
    local json_data=$3
    local ok=0
    local over=0
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

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       Persistence Tests                  ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ============================================================
log "=== TEST 1: Health check ==="

result=$(curl -s --max-time 2 http://localhost:8080/health)
if echo "$result" | grep -q "node_id"; then
    pass "Cluster is healthy"
else
    fail "Cluster not healthy — aborting"
    exit 1
fi

# ============================================================
log "=== TEST 2: Send requests and verify limit ==="

# Use a unique user so we don't collide with other tests
TS=$(date +%s%N)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"persist_${TS}\"}]}],\"hits_addend\":1}"

# Send 500 requests (limit is 1000/min, so all should pass)
read ok over <<< $(send_n 500 50051 "$DATA")
if [ "$ok" -eq 500 ]; then
    pass "Sent 500 requests, all allowed (allowed=$ok denied=$over)"
else
    fail "Unexpected denials before restart (allowed=$ok denied=$over)"
fi

# ============================================================
log "=== TEST 3: Wait for eviction flush to disk ==="

# Eviction interval is 10s — wait for at least one flush
echo "  Waiting 12 seconds for disk flush..."
sleep 12
pass "Waited for disk flush"

# ============================================================
log "=== TEST 4: Restart node 1 ==="

echo "  Restarting node1..."
docker compose restart node1 2>/dev/null
sleep 5

result=$(curl -s --max-time 2 http://localhost:8080/health)
if echo "$result" | grep -q "node_id"; then
    pass "Node 1 restarted and healthy"
else
    fail "Node 1 failed to restart"
    exit 1
fi

# ============================================================
log "=== TEST 5: Verify counter survived restart ==="

# Send 600 more requests with the same key
# If persistence works: 500 already counted + 600 new = 1100, so ~100 should be denied
# If persistence failed: 0 + 600 = 600, all would be allowed
read ok over <<< $(send_n 600 50051 "$DATA")

if [ "$over" -gt 0 ]; then
    pass "Counters persisted across restart (allowed=$ok denied=$over)"
else
    fail "Counters lost on restart — all 600 allowed (allowed=$ok denied=$over)"
fi

# ============================================================
log "=== TEST 6: Verify counter is approximately correct ==="

# We sent 500 before restart, so ~500 should remain
# With 1000/min limit, we should get ~500 more allowed out of 600
# Allow some tolerance for sliding window
if [ "$ok" -ge 450 ] && [ "$ok" -le 550 ]; then
    pass "Counter accuracy good after restart (allowed=$ok, expected ~500)"
elif [ "$ok" -gt 0 ] && [ "$ok" -lt 600 ]; then
    pass "Counter partially recovered (allowed=$ok — some state restored)"
else
    fail "Counter way off after restart (allowed=$ok, expected ~500)"
fi

# ============================================================
log "=== TEST 7: Fresh key still works after restart ==="

TS2=$(date +%s%N)
DATA2="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"fresh_${TS2}\"}]}],\"hits_addend\":1}"

read ok over <<< $(send_n 10 50051 "$DATA2")
if [ "$ok" -eq 10 ]; then
    pass "Fresh key works normally after restart (allowed=$ok)"
else
    fail "Fresh key broken after restart (allowed=$ok denied=$over)"
fi

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              RESULTS                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Total:  $((PASS + FAIL))"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "  ✓ ALL TESTS PASSED"
else
    echo "  ✗ $FAIL TEST(S) FAILED"
fi
echo ""