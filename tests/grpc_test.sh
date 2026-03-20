#!/bin/bash
# tests/grpc_test.sh - gRPC rate limit service tests

PROTO="proto/rls.proto"
ADDR="localhost:50051"
SERVICE="envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit"
RUN_ID=$(date +%s)
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

call_rls() {
    local domain=$1 key=$2 value=$3 hits=${4:-1}
    grpcurl -plaintext -proto $PROTO -d "{
        \"domain\": \"$domain\",
        \"descriptors\": [{\"entries\": [{\"key\": \"$key\", \"value\": \"$value\"}]}],
        \"hits_addend\": $hits
    }" $ADDR $SERVICE 2>&1
}

call_rls_multi() {
    local domain=$1
    grpcurl -plaintext -proto $PROTO -d "{
        \"domain\": \"$domain\",
        \"descriptors\": [
            {\"entries\": [{\"key\": \"user_id\", \"value\": \"multi_$RUN_ID\"}]},
            {\"entries\": [{\"key\": \"path\", \"value\": \"/api/search\"}]}
        ],
        \"hits_addend\": 1
    }" $ADDR $SERVICE 2>&1
}

# ============================================================
log "TEST 1: Single request returns OK"

RESP=$(call_rls "api" "user_id" "t1_$RUN_ID")
assert "single request OK" "echo '$RESP' | grep -q '\"overallCode\": \"OK\"'"

# ============================================================
log "TEST 2: Remaining decreases"

R1=$(call_rls "api" "user_id" "t2_$RUN_ID" | grep limitRemaining | grep -o '[0-9]*')
R2=$(call_rls "api" "user_id" "t2_$RUN_ID" | grep limitRemaining | grep -o '[0-9]*')
echo "  remaining: $R1 -> $R2"
assert "remaining decreased" "[ '$R2' -lt '$R1' ]"

# ============================================================
log "TEST 3: hits_addend burns multiple"

R1=$(call_rls "api" "user_id" "t3_$RUN_ID" 1 | grep limitRemaining | grep -o '[0-9]*')
R2=$(call_rls "api" "user_id" "t3_$RUN_ID" 5 | grep limitRemaining | grep -o '[0-9]*')
DIFF=$((R1 - R2))
echo "  remaining: $R1 -> $R2 (diff=$DIFF)"
assert "burned 5 hits" "[ $DIFF -eq 5 ]"

# ============================================================
log "TEST 4: Exceed limit returns OVER_LIMIT"

call_rls "api" "user_id" "t4_$RUN_ID" 1000 > /dev/null
RESP=$(call_rls "api" "user_id" "t4_$RUN_ID" 1)
assert "got OVER_LIMIT" "echo '$RESP' | grep -q '\"overallCode\": \"OVER_LIMIT\"'"

# ============================================================
log "TEST 5: Different keys are independent"

call_rls "api" "user_id" "t5a_$RUN_ID" 99 > /dev/null
RESP=$(call_rls "api" "user_id" "t5b_$RUN_ID" 1)
assert "different key unaffected" "echo '$RESP' | grep -q '\"overallCode\": \"OK\"'"

# ============================================================
log "TEST 6: Different domains are independent"

call_rls "domain_a" "user_id" "t6_$RUN_ID" 99 > /dev/null
RESP=$(call_rls "domain_b" "user_id" "t6_$RUN_ID" 1)
assert "different domain unaffected" "echo '$RESP' | grep -q '\"overallCode\": \"OK\"'"

# ============================================================
log "TEST 7: Multi-descriptor returns multiple statuses"

RESP=$(call_rls_multi "api")
STATUS_COUNT=$(echo "$RESP" | grep -c '"code"')
echo "  status count: $STATUS_COUNT"
assert "got 2 descriptor statuses" "[ $STATUS_COUNT -eq 2 ]"

# ============================================================
log "TEST 8: Gossip propagates gRPC requests"

for i in $(seq 1 50); do
    call_rls "api" "user_id" "t8_$RUN_ID" 1 > /dev/null
done
sleep 0.5
RESP=$(grpcurl -plaintext -proto $PROTO -d "{
    \"domain\": \"api\",
    \"descriptors\": [{\"entries\": [{\"key\": \"user_id\", \"value\": \"t8_$RUN_ID\"}]}],
    \"hits_addend\": 1
}" localhost:50052 $SERVICE 2>&1)
REM=$(echo "$RESP" | grep limitRemaining | grep -o '[0-9]*')
echo "  node2 remaining: $REM (expect ~49 if gossip propagated)"
assert "gossip propagated to node2" "[ -n '$REM' ] && [ '$REM' -lt 960 ]"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL