#!/bin/bash
# super_stress_test.sh — push the cluster to its limits

BASE_URL_1="http://localhost:8080"
BASE_URL_2="http://localhost:8081"
BASE_URL_3="http://localhost:8082"

WINDOW=60000
RUN_ID=$(date +%s)

fire_request() {
  local url=$1 key=$2 limit=$3
  curl -s -X POST "$url/check" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$key\",\"limit\":$limit,\"hits\":1,\"window_ms\":$WINDOW}"
}

echo "============================================"
echo "  SUPER STRESS TEST — $RUN_ID"
echo "============================================"

# --- Test 1: 1000 sequential requests, single node ---
echo ""
echo "--- Test 1: 1000 sequential to node1, limit 100 ---"
ALLOW=0; DENY=0
for i in $(seq 1 1000); do
  RESP=$(fire_request $BASE_URL_1 "super:seq:$RUN_ID" 100)
  if echo "$RESP" | grep -q '"status":200'; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
echo "  Result: $ALLOW allowed, $DENY denied (expect ~100 allowed)"

# --- Test 2: 500 parallel requests, single node ---
echo ""
echo "--- Test 2: 500 parallel to node1, limit 200 ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 500); do
  fire_request $BASE_URL_1 "super:parallel:$RUN_ID" 200 > "$tmpdir/$i.txt" &
done
wait
ALLOW=0; DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $ALLOW allowed, $DENY denied (expect ~200 allowed)"

# --- Test 3: 1500 parallel across 3 nodes ---
echo ""
echo "--- Test 3: 1500 parallel across 3 nodes, limit 300 ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 500); do
  fire_request $BASE_URL_1 "super:dist:$RUN_ID" 300 > "$tmpdir/n1_$i.txt" &
  fire_request $BASE_URL_2 "super:dist:$RUN_ID" 300 > "$tmpdir/n2_$i.txt" &
  fire_request $BASE_URL_3 "super:dist:$RUN_ID" 300 > "$tmpdir/n3_$i.txt" &
done
wait
ALLOW=0; DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $ALLOW allowed, $DENY denied (expect ~300, gossip overshoot likely)"

# --- Test 4: 500 unique keys, 20 requests each (batched parallel) ---
echo ""
echo "--- Test 4: 500 unique keys x 20 requests, limit 10 ---"
tmpdir=$(mktemp -d)
for k in $(seq 1 500); do
  for r in $(seq 1 20); do
    NODE=$((RANDOM % 3 + 1))
    fire_request "http://localhost:$((8079 + NODE))/check" "super:key_${k}:$RUN_ID" 10 > "$tmpdir/k${k}_r${r}.txt" &
  done
  # flush every 100 keys to avoid spawning 10000 curls at once
  if (( k % 100 == 0 )); then
    wait
    echo "  ...batch $k/500 done"
  fi
done
wait
TOTAL_ALLOW=0; TOTAL_DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then TOTAL_ALLOW=$((TOTAL_ALLOW+1)); else TOTAL_DENY=$((TOTAL_DENY+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $TOTAL_ALLOW allowed, $TOTAL_DENY denied across 10000 requests"
echo "  (expect ~5000 allowed = 500 keys x 10 each)"

# --- Test 5: rapid fire waves with gossip gaps ---
echo ""
echo "--- Test 5: 5 waves of 200 parallel, 200ms gaps ---"
TOTAL_ALLOW=0; TOTAL_DENY=0
for wave in $(seq 1 5); do
  tmpdir=$(mktemp -d)
  for i in $(seq 1 200); do
    NODE=$((RANDOM % 3 + 1))
    fire_request "http://localhost:$((8079 + NODE))/check" "super:wave:$RUN_ID" 150 > "$tmpdir/$i.txt" &
  done
  wait
  for f in "$tmpdir"/*.txt; do
    if grep -q '"status":200' "$f"; then TOTAL_ALLOW=$((TOTAL_ALLOW+1)); else TOTAL_DENY=$((TOTAL_DENY+1)); fi
  done
  rm -rf "$tmpdir"
  echo "  Wave $wave done: running total $TOTAL_ALLOW allowed"
  sleep 0.2
done
echo "  Final: $TOTAL_ALLOW allowed, $TOTAL_DENY denied out of 1000 (expect ~150 allowed)"

# --- Test 6: gossip convergence — heavy burst then immediate cross-check ---
echo ""
echo "--- Test 6: burst 100 to node1, immediate check node2 + node3 ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 100); do
  fire_request $BASE_URL_1 "super:converge:$RUN_ID" 200 > "$tmpdir/$i.txt" &
done
wait
N1_ALLOW=$(grep -l '"status":200' "$tmpdir"/*.txt | wc -l)
rm -rf "$tmpdir"
echo "  Node1 allowed: $N1_ALLOW out of 100"

echo "  Checking node2 immediately (no wait)..."
RESP2=$(fire_request $BASE_URL_2 "super:converge:$RUN_ID" 200)
REM2=$(echo "$RESP2" | grep -o '"remaining":[0-9]*' | cut -d: -f2)
echo "  Node2 remaining: $REM2 (high = gossip hasn't arrived)"

echo "  Waiting 500ms for gossip..."
sleep 0.5
RESP3=$(fire_request $BASE_URL_3 "super:converge:$RUN_ID" 200)
REM3=$(echo "$RESP3" | grep -o '"remaining":[0-9]*' | cut -d: -f2)
echo "  Node3 remaining after gossip: $REM3 (should be ~$((200 - N1_ALLOW - 2)))"

# --- Test 7: sustained high throughput ---
echo ""
echo "--- Test 7: sustained 100 req/sec for 10 seconds ---"
ALLOW=0; DENY=0
for sec in $(seq 1 10); do
  tmpdir=$(mktemp -d)
  for i in $(seq 1 100); do
    NODE=$((RANDOM % 3 + 1))
    fire_request "http://localhost:$((8079 + NODE))/check" "super:sustained:$RUN_ID" 500 > "$tmpdir/$i.txt" &
  done
  wait
  for f in "$tmpdir"/*.txt; do
    if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
  done
  rm -rf "$tmpdir"
  echo "  Second $sec: $ALLOW allowed so far"
  sleep 1
done
echo "  Final: $ALLOW allowed, $DENY denied out of 1000 (expect ~500 allowed)"

# --- Test 8: maximum parallel connections ---
echo ""
echo "--- Test 8: 2000 simultaneous requests across cluster ---"
tmpdir=$(mktemp -d)
for i in $(seq 1 2000); do
  NODE=$((RANDOM % 3 + 1))
  fire_request "http://localhost:$((8079 + NODE))/check" "super:max:$RUN_ID" 500 > "$tmpdir/$i.txt" &
done
wait
ALLOW=0; DENY=0
for f in "$tmpdir"/*.txt; do
  if grep -q '"status":200' "$f"; then ALLOW=$((ALLOW+1)); else DENY=$((DENY+1)); fi
done
ERRORS=0
for f in "$tmpdir"/*.txt; do
  if [ ! -s "$f" ]; then ERRORS=$((ERRORS+1)); fi
done
rm -rf "$tmpdir"
echo "  Result: $ALLOW allowed, $DENY denied, $ERRORS errors (expect ~500 allowed, 0 errors)"

echo ""
echo "============================================"
echo "  SUPER STRESS TEST COMPLETE"
echo "============================================"
echo ""
echo "  Metrics snapshot:"
curl -s http://localhost:9090/metrics | grep -E "^(rate_limit|gossip|store)"