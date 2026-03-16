#!/bin/bash
# stress_test.sh — hammer the cluster hard

BASE_URL_1="http://localhost:8080"
BASE_URL_2="http://localhost:8081"
BASE_URL_3="http://localhost:8082"

WINDOW=60000

fire_request() {
  local url=$1 key=$2 limit=$3
  curl -s -X POST "$url/check" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$key\",\"limit\":$limit,\"hits\":1,\"window_ms\":$WINDOW}"
}

count_results() {
  local allow=0 deny=0
  while IFS= read -r line; do
    if echo "$line" | grep -q '"status":200'; then
      allow=$((allow + 1))
    else
      deny=$((deny + 1))
    fi
  done
  echo "$allow allowed, $deny denied"
}

echo "========================================="
echo "  STRESS TEST — distributed rate limiter"
echo "========================================="

# --- Test 1: 200 sequential requests, single node ---
echo ""
echo "--- Test 1: 200 requests to node1, limit 50 ---"
ALLOW=0; DENY=0
for i in $(seq 1 200); do
  RESP=$(fire_request $BASE_URL_1 "stress:sequential" 50)
  if echo "$RESP" | grep -q '"status":200'; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
echo "  Result: $ALLOW allowed, $DENY denied (expect ~50 allowed)"

# --- Test 2: 100 parallel requests, single node ---
echo ""
echo "--- Test 2: 100 parallel requests to node1, limit 40 ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 100); do
  fire_request $BASE_URL_1 "stress:parallel" 40 > "$tmpdir/$i.txt" &
done
wait
ALLOW=0; DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $ALLOW allowed, $DENY denied (expect ~40 allowed, some overshoot ok)"

# --- Test 3: 300 parallel requests split across all 3 nodes ---
echo ""
echo "--- Test 3: 300 parallel requests across 3 nodes, limit 100 ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 100); do
  fire_request $BASE_URL_1 "stress:distributed" 100 > "$tmpdir/n1_$i.txt" &
  fire_request $BASE_URL_2 "stress:distributed" 100 > "$tmpdir/n2_$i.txt" &
  fire_request $BASE_URL_3 "stress:distributed" 100 > "$tmpdir/n3_$i.txt" &
done
wait
ALLOW=0; DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $ALLOW allowed, $DENY denied (expect ~100 allowed, gossip delay may cause overshoot)"

# --- Test 4: 50 unique keys, 10 requests each ---
echo ""
echo "--- Test 4: 50 unique keys, 10 requests each, limit 5 ---"
TOTAL_ALLOW=0; TOTAL_DENY=0
for k in $(seq 1 50); do
  KEY_ALLOW=0
  for r in $(seq 1 10); do
    RESP=$(fire_request $BASE_URL_1 "stress:key_$k" 5)
    if echo "$RESP" | grep -q '"status":200'; then KEY_ALLOW=$((KEY_ALLOW+1)); fi
  done
  TOTAL_ALLOW=$((TOTAL_ALLOW + KEY_ALLOW))
  TOTAL_DENY=$((TOTAL_DENY + 10 - KEY_ALLOW))
done
echo "  Result: $TOTAL_ALLOW allowed, $TOTAL_DENY denied across 500 requests"
echo "  (expect ~250 allowed = 50 keys x 5 each)"

# --- Test 5: gossip convergence under load ---
echo ""
echo "--- Test 5: gossip convergence — burst node1, check node2 ---"
for i in $(seq 1 25); do
  fire_request $BASE_URL_1 "stress:convergence" 30 > /dev/null &
done
wait
echo "  Sent 25 to node1, waiting 300ms for gossip..."
sleep 0.3
RESP=$(fire_request $BASE_URL_2 "stress:convergence" 30)
REMAINING=$(echo "$RESP" | grep -o '"remaining":[0-9]*' | cut -d: -f2)
echo "  Node2 sees remaining: $REMAINING (expect ~4, meaning ~25 propagated)"

# --- Test 6: sustained throughput ---
echo ""
echo "--- Test 6: sustained load — 10 req/sec for 5 seconds across nodes ---"
ALLOW=0; DENY=0
for sec in $(seq 1 5); do
  for i in $(seq 1 10); do
    NODE=$((RANDOM % 3))
    case $NODE in
      0) URL=$BASE_URL_1 ;; 1) URL=$BASE_URL_2 ;; 2) URL=$BASE_URL_3 ;;
    esac
    RESP=$(fire_request $URL "stress:sustained" 30)
    if echo "$RESP" | grep -q '"status":200'; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
  done
  sleep 1
done
echo "  Result: $ALLOW allowed, $DENY denied out of 50 (expect ~30 allowed)"

echo ""
echo "========================================="
echo "  STRESS TEST COMPLETE"
echo "========================================="