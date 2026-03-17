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

# Send n sequential requests, count OK vs OVER_LIMIT
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
if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
    fail "Unknown domain incorrectly denied"
else
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
log "=== TEST 4: Free tier limit enforced (600/min) ==="

# Send 610 requests — first 600 should pass, last 10 denied
DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 620 50051 "$DATA")
if [ "$ok" -ge 595 ] && [ "$ok" -le 610 ]; then
    pass "Free tier limit ~600/min (allowed=$ok denied=$over)"
else
    fail "Free tier limit wrong (allowed=$ok denied=$over expected ~600)"
fi

# ============================================================
log "=== TEST 5: Premium tier has higher limit than free ==="

# Free is exhausted from test 4. Premium has 6000/min — send 100, all should pass
DATA_FREE="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
DATA_PREMIUM="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"}]}],\"hits_addend\":1}"
read free_ok free_over <<< $(send_n 10 50051 "$DATA_FREE")
read premium_ok premium_over <<< $(send_n 100 50051 "$DATA_PREMIUM")
if [ "$premium_ok" -gt "$free_ok" ]; then
    pass "Premium tier allows more than free (premium=$premium_ok free=$free_ok)"
else
    fail "Premium tier not higher than free (premium=$premium_ok free=$free_ok)"
fi

# ============================================================
log "=== TEST 6: Premium + search path hits search limit (600/min) ==="

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/search\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 620 50051 "$DATA")
if [ "$ok" -ge 595 ] && [ "$ok" -le 610 ]; then
    pass "Premium+search limit ~600/min (allowed=$ok denied=$over)"
else
    fail "Premium+search limit wrong (allowed=$ok denied=$over expected ~600)"
fi

# ============================================================
log "=== TEST 7: Premium without search path uses premium limit ==="

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/other\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 100 50051 "$DATA")
if [ "$ok" -eq 100 ] && [ "$over" -eq 0 ]; then
    pass "Premium non-search path uses premium limit (allowed=$ok denied=$over)"
else
    fail "Premium non-search path wrong (allowed=$ok denied=$over expected 100/0)"
fi

# ============================================================
log "=== TEST 8: Per-user limit in api domain (1000/min) ==="

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 1020 50051 "$DATA")
if [ "$ok" -ge 995 ] && [ "$ok" -le 1010 ]; then
    pass "Per-user limit ~1000/min (allowed=$ok denied=$over)"
else
    fail "Per-user limit wrong (allowed=$ok denied=$over expected ~1000)"
fi

# ============================================================
log "=== TEST 9: Different users are independent ==="

TS=$(unique_key)
DATA_A="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_a_${TS}\"}]}],\"hits_addend\":1}"
DATA_B="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_b_${TS}\"}]}],\"hits_addend\":1}"
read ok_a over_a <<< $(send_n 50 50051 "$DATA_A")
read ok_b over_b <<< $(send_n 50 50051 "$DATA_B")
if [ "$ok_a" -eq 50 ] && [ "$ok_b" -eq 50 ]; then
    pass "Different users have independent limits (user_a=$ok_a user_b=$ok_b)"
else
    fail "Users sharing limits (user_a=$ok_a user_b=$ok_b expected 50/50)"
fi

# ============================================================
log "=== TEST 10: hits_addend counts correctly ==="

TS=$(unique_key)
# Per-user limit = 1000/min. hits_addend=400. First 2 use 800, third (800+400=1200>1000) denied
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"hits_${TS}\"}]}],\"hits_addend\":400}"
read ok over <<< $(send_n 5 50051 "$DATA")
if [ "$ok" -eq 2 ] && [ "$over" -eq 3 ]; then
    pass "hits_addend=400 correctly consumes 400 hits per request (allowed=$ok denied=$over)"
else
    fail "hits_addend not working correctly (allowed=$ok denied=$over expected 2/3)"
fi

# ============================================================
log "=== TEST 11: Multiple descriptors — both enforced ==="

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_a_${TS}\"}]},{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_b_${TS}\"}]}],\"hits_addend\":1}"
# Both descriptors use unique user_ids with 1000/min limit each
# After 1000 requests, both should be at limit
read ok over <<< $(send_n 1020 50051 "$DATA")
if [ "$ok" -ge 995 ] && [ "$ok" -le 1010 ]; then
    pass "Multiple descriptors enforced ~1000/min (allowed=$ok denied=$over)"
else
    fail "Multiple descriptors wrong (allowed=$ok denied=$over expected ~1000)"
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
log "=== TEST 14: Ultra tier allows high-frequency traffic ==="

# Ultra = 60,000/min. Send 500 quickly — all should pass
DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"ultra\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 500 50051 "$DATA")
if [ "$ok" -eq 500 ] && [ "$over" -eq 0 ]; then
    pass "Ultra tier allows 500 rapid requests (allowed=$ok denied=$over)"
else
    fail "Ultra tier wrong (allowed=$ok denied=$over expected 500/0)"
fi

# ============================================================
log "=== TEST 15: Internal domain service limit (10000/min) ==="

TS=$(unique_key)
DATA="{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"svc_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 100 50051 "$DATA")
if [ "$ok" -eq 100 ] && [ "$over" -eq 0 ]; then
    pass "Internal service allows 100 requests (allowed=$ok denied=$over)"
else
    fail "Internal service wrong (allowed=$ok denied=$over expected 100/0)"
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