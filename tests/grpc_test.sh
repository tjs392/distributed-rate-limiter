#!/bin/bash
# grpc_test.sh — test the gRPC rate limit service

PROTO="proto/rls.proto"
ADDR="localhost:50051"
SERVICE="envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit"
RUN_ID=$(date +%s)

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

echo "==========================================="
echo "  gRPC RATE LIMIT SERVICE TESTS — $RUN_ID"
echo "==========================================="

# --- Test 1: single request returns OK ---
echo ""
echo "--- Test 1: single request returns OK ---"
RESP=$(call_rls "test" "user_id" "t1_$RUN_ID")
if echo "$RESP" | grep -q '"overallCode": "OK"'; then
  echo "  PASS: got OK"
else
  echo "  FAIL: expected OK, got: $RESP"
fi

# --- Test 2: remaining decreases ---
echo ""
echo "--- Test 2: remaining decreases ---"
R1=$(call_rls "test" "user_id" "t2_$RUN_ID" | grep limitRemaining | grep -o '[0-9]*')
R2=$(call_rls "test" "user_id" "t2_$RUN_ID" | grep limitRemaining | grep -o '[0-9]*')
if [ "$R2" -lt "$R1" ]; then
  echo "  PASS: remaining decreased from $R1 to $R2"
else
  echo "  FAIL: remaining didn't decrease ($R1 -> $R2)"
fi

# --- Test 3: hits_addend works ---
echo ""
echo "--- Test 3: hits_addend burns multiple ---"
R1=$(call_rls "test" "user_id" "t3_$RUN_ID" 1 | grep limitRemaining | grep -o '[0-9]*')
R2=$(call_rls "test" "user_id" "t3_$RUN_ID" 5 | grep limitRemaining | grep -o '[0-9]*')
DIFF=$((R1 - R2))
if [ "$DIFF" -eq 5 ]; then
  echo "  PASS: burned 5 hits (remaining $R1 -> $R2)"
else
  echo "  FAIL: expected 5 hit decrease, got $DIFF ($R1 -> $R2)"
fi

# --- Test 4: exceeds limit returns OVER_LIMIT ---
echo ""
echo "--- Test 4: exceed limit returns OVER_LIMIT ---"
call_rls "test" "user_id" "t4_$RUN_ID" 100 > /dev/null
RESP=$(call_rls "test" "user_id" "t4_$RUN_ID" 1)
if echo "$RESP" | grep -q '"overallCode": "OVER_LIMIT"'; then
  echo "  PASS: got OVER_LIMIT"
else
  echo "  FAIL: expected OVER_LIMIT, got: $RESP"
fi

# --- Test 5: different keys are independent ---
echo ""
echo "--- Test 5: different keys are independent ---"
call_rls "test" "user_id" "t5a_$RUN_ID" 99 > /dev/null
RESP=$(call_rls "test" "user_id" "t5b_$RUN_ID" 1)
if echo "$RESP" | grep -q '"overallCode": "OK"'; then
  echo "  PASS: different key unaffected"
else
  echo "  FAIL: different key was affected"
fi

# --- Test 6: different domains are independent ---
echo ""
echo "--- Test 6: different domains are independent ---"
call_rls "domain_a" "user_id" "t6_$RUN_ID" 99 > /dev/null
RESP=$(call_rls "domain_b" "user_id" "t6_$RUN_ID" 1)
if echo "$RESP" | grep -q '"overallCode": "OK"'; then
  echo "  PASS: different domain unaffected"
else
  echo "  FAIL: different domain was affected"
fi

# --- Test 7: multi-descriptor returns multiple statuses ---
echo ""
echo "--- Test 7: multi-descriptor returns two statuses ---"
RESP=$(call_rls_multi "test")
STATUS_COUNT=$(echo "$RESP" | grep -c '"code"')
if [ "$STATUS_COUNT" -eq 2 ]; then
  echo "  PASS: got 2 descriptor statuses"
else
  echo "  FAIL: expected 2 statuses, got $STATUS_COUNT"
fi

# --- Test 8: gossip propagates gRPC requests ---
echo ""
echo "--- Test 8: gossip propagation via gRPC ---"
for i in $(seq 1 50); do
  call_rls "test" "user_id" "t8_$RUN_ID" 1 > /dev/null
done
echo "  Sent 50 to node1 (port 50051), waiting 500ms..."
sleep 0.5
RESP=$(grpcurl -plaintext -proto $PROTO -d "{
  \"domain\": \"test\",
  \"descriptors\": [{\"entries\": [{\"key\": \"user_id\", \"value\": \"t8_$RUN_ID\"}]}],
  \"hits_addend\": 1
}" localhost:50052 $SERVICE 2>&1)
REM=$(echo "$RESP" | grep limitRemaining | grep -o '[0-9]*')
echo "  Node2 remaining: $REM (expect ~49, meaning gossip propagated)"

echo ""
echo "==========================================="
echo "  gRPC TESTS COMPLETE"
echo "==========================================="