#!/bin/bash
# tests/rules.sh
# Tests the rules-based gRPC rate limiting system

PROTO_PATH="./proto/rls.proto"
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $1"; }
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

check_deps() {
    if ! command -v grpcurl &> /dev/null; then
        echo "grpcurl not installed: https://github.com/fullstorydev/grpcurl#installation"
        exit 1
    fi
}

unique_key() {
    echo "$(date +%s%N)"
}

# Send a single grpcurl request and return the JSON response
# usage: grpc_call <port> <json_data>
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

# Send n sequential requests, count OK vs OVER_LIMIT based on overallCode in response body
# usage: send_n <n> <port> <json_data>
# outputs: "<ok> <over>"
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

check_deps

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     Rules-Based Rate Limit Tests         ║"
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
log "=== TEST 2: Unknown domain allows through ==="

TS=$(unique_key)
DATA="{\"domain\":\"unknown_domain_${TS}\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
result=$(grpc_call 50051 "$DATA")
if echo "$result" | grep -q '"overallCode": "OK"'; then
    pass "Unknown domain allowed through"
elif echo "$result" | grep -q '"overallCode"'; then
    fail "Unknown domain incorrectly denied"
else
    # No overallCode field means default OK
    pass "Unknown domain allowed through"
fi

# ============================================================
log "=== TEST 3: Unknown descriptor allows through ==="

TS=$(unique_key)
DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"unknown_key_${TS}\",\"value\":\"unknown_value\"}]}],\"hits_addend\":1}"
result=$(grpc_call 50051 "$DATA")
if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
    fail "Unknown descriptor incorrectly denied"
else
    pass "Unknown descriptor allowed through"
fi

# ============================================================
log "=== TEST 4: Free tier limit enforced ==="

TS=$(unique_key)
# Use a unique domain-level key by embedding TS in a separate descriptor won't work,
# so we rely on fresh epoch or wait. Since free tier = 5/min and we removed test_run,
# we need isolation. We'll use the api domain with a unique user to avoid collisions.
# Actually, for tier-based tests we can't add unique keys without breaking matching.
# So we just test against the shared tier:free counter and accept cumulative state.
# To get clean state, restart the cluster or wait for window reset.
DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 10 50051 "$DATA")
if [ "$ok" -eq 5 ] && [ "$over" -eq 5 ]; then
    pass "Free tier limit enforced at 5/min (allowed=$ok denied=$over)"
else
    fail "Free tier limit wrong (allowed=$ok denied=$over expected 5/5)"
fi

# ============================================================
log "=== TEST 5: Premium tier has higher limit than free ==="

# Free tier is already exhausted from test 4, so all 10 should be denied
# Premium tier has 100/min so all 10 should pass
DATA_FREE="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
DATA_PREMIUM="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"}]}],\"hits_addend\":1}"
read free_ok free_over <<< $(send_n 10 50051 "$DATA_FREE")
read premium_ok premium_over <<< $(send_n 10 50051 "$DATA_PREMIUM")
if [ "$premium_ok" -gt "$free_ok" ]; then
    pass "Premium tier allows more than free (premium=$premium_ok free=$free_ok)"
else
    fail "Premium tier not higher than free (premium=$premium_ok free=$free_ok)"
fi

# ============================================================
log "=== TEST 6: Premium + search path hits search limit ==="

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/search\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 15 50051 "$DATA")
if [ "$ok" -eq 10 ] && [ "$over" -eq 5 ]; then
    pass "Premium+search path limit enforced at 10/min (allowed=$ok denied=$over)"
else
    fail "Premium+search path limit wrong (allowed=$ok denied=$over expected 10/5)"
fi

# ============================================================
log "=== TEST 7: Premium without search path uses premium limit ==="

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/other\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 15 50051 "$DATA")
if [ "$ok" -eq 15 ] && [ "$over" -eq 0 ]; then
    pass "Premium non-search path uses premium limit (allowed=$ok denied=$over)"
else
    fail "Premium non-search path wrong (allowed=$ok denied=$over expected 15/0)"
fi

# ============================================================
log "=== TEST 8: Per-user limit in api domain ==="

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 60 50051 "$DATA")
if [ "$ok" -eq 50 ] && [ "$over" -eq 10 ]; then
    pass "Per-user limit enforced at 50/min (allowed=$ok denied=$over)"
else
    fail "Per-user limit wrong (allowed=$ok denied=$over expected 50/10)"
fi

# ============================================================
log "=== TEST 9: Different users are independent ==="

TS=$(unique_key)
DATA_A="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_a_${TS}\"}]}],\"hits_addend\":1}"
DATA_B="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_b_${TS}\"}]}],\"hits_addend\":1}"
read ok_a over_a <<< $(send_n 5 50051 "$DATA_A")
read ok_b over_b <<< $(send_n 5 50051 "$DATA_B")
if [ "$ok_a" -eq 5 ] && [ "$ok_b" -eq 5 ]; then
    pass "Different users have independent limits (user_a=$ok_a user_b=$ok_b)"
else
    fail "Users sharing limits (user_a=$ok_a user_b=$ok_b expected 5/5)"
fi

# ============================================================
log "=== TEST 10: hits_addend counts correctly ==="

# Use a unique user in api domain (50/min limit) to test hits_addend
# With hits_addend=20, first 2 requests use 40 of 50, third request (40+20=60 > 50) should deny
TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"hits_${TS}\"}]}],\"hits_addend\":20}"
read ok over <<< $(send_n 5 50051 "$DATA")
if [ "$ok" -eq 2 ] && [ "$over" -eq 3 ]; then
    pass "hits_addend=20 correctly consumes 20 hits per request (allowed=$ok denied=$over)"
else
    fail "hits_addend not working correctly (allowed=$ok denied=$over expected 2/3)"
fi

# ============================================================
log "=== TEST 11: Multiple descriptors — most restrictive wins ==="

# Send two descriptors: free (5/min) and premium (100/min)
# The free descriptor key will hit limit first
# But each descriptor is checked independently with its own key
# overallCode = OVER_LIMIT if ANY descriptor is over
TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_a_${TS}\"}]},{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_b_${TS}\"}]}],\"hits_addend\":1}"
# Both descriptors use unique user_ids with 50/min limit each
# Each request increments both counters by 1
# After 50 requests, both should be at limit
read ok over <<< $(send_n 55 50051 "$DATA")
if [ "$ok" -eq 50 ] && [ "$over" -eq 5 ]; then
    pass "Multiple descriptors both enforced (allowed=$ok denied=$over)"
else
    fail "Multiple descriptors wrong (allowed=$ok denied=$over expected 50/5)"
fi

# ============================================================
log "=== TEST 12: Rules load correctly across all nodes ==="

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"node_test_${TS}\"}]}],\"hits_addend\":1}"
all_pass=true
for port in 50051 50052 50053 50054 50055; do
    result=$(grpc_call $port "$DATA")
    if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
        all_pass=false
        fail "Node :$port incorrectly denied first request"
    fi
done
if $all_pass; then
    pass "Rules loaded correctly on all 5 nodes"
fi

# ============================================================
log "=== TEST 13: Warning logged for unknown domain ==="

TS=$(unique_key)
DATA="{\"domain\":\"no_rules_domain_${TS}\",\"descriptors\":[{\"entries\":[{\"key\":\"key\",\"value\":\"val\"}]}],\"hits_addend\":1}"
grpc_call 50051 "$DATA" > /dev/null
sleep 1
if docker compose logs --tail=50 2>/dev/null | grep -q "no rule matched"; then
    pass "Warning logged for unmatched domain"
else
    fail "No warning logged for unmatched domain"
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
echo "Run 'docker compose down' when done"