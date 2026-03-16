#!/bin/bash
# demo_test.sh - batter the 3-node cluster

BASE_URL_1="http://localhost:8080"
BASE_URL_2="http://localhost:8081"
BASE_URL_3="http://localhost:8082"

KEY="user:loadtest"
LIMIT=20
WINDOW=60000

echo "=== Health checks ==="
curl -s $BASE_URL_1/health | jq .
curl -s $BASE_URL_2/health | jq .
curl -s $BASE_URL_3/health | jq .

echo ""
echo "=== Sending 10 requests to node 1 ==="
for i in $(seq 1 10); do
  RESP=$(curl -s -X POST $BASE_URL_1/check \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$KEY\",\"limit\":$LIMIT,\"hits\":1,\"window_ms\":$WINDOW}")
  echo "  node1 req $i: $RESP"
done

echo ""
echo "=== Waiting 500ms for gossip propagation ==="
sleep 0.5

echo ""
echo "=== Sending 5 requests to node 2 ==="
for i in $(seq 1 5); do
  RESP=$(curl -s -X POST $BASE_URL_2/check \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$KEY\",\"limit\":$LIMIT,\"hits\":1,\"window_ms\":$WINDOW}")
  echo "  node2 req $i: $RESP"
done

echo ""
echo "=== Waiting 500ms for gossip propagation ==="
sleep 0.5

echo ""
echo "=== Sending 5 requests to node 3 ==="
for i in $(seq 1 5); do
  RESP=$(curl -s -X POST $BASE_URL_3/check \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$KEY\",\"limit\":$LIMIT,\"hits\":1,\"window_ms\":$WINDOW}")
  echo "  node3 req $i: $RESP"
done

echo ""
echo "=== Should be at or near limit now. Trying 3 more on each node ==="
sleep 0.5

for NODE_URL in $BASE_URL_1 $BASE_URL_2 $BASE_URL_3; do
  RESP=$(curl -s -X POST $NODE_URL/check \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$KEY\",\"limit\":$LIMIT,\"hits\":1,\"window_ms\":$WINDOW}")
  echo "  $NODE_URL: $RESP"
done

echo ""
echo "=== Different keys should be independent ==="
RESP=$(curl -s -X POST $BASE_URL_1/check \
  -H "Content-Type: application/json" \
  -d '{"key":"api:search","limit":100,"hits":1,"window_ms":60000}')
echo "  node1 different key: $RESP"

echo ""
echo "=== Rapid fire: 50 requests as fast as possible to node 1 ==="
ALLOW=0
DENY=0
for i in $(seq 1 50); do
  RESP=$(curl -s -X POST $BASE_URL_1/check \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"rapid_key\",\"limit\":30,\"hits\":1,\"window_ms\":60000}")
  if echo "$RESP" | grep -q '"status":200'; then
    ALLOW=$((ALLOW + 1))
  else
    DENY=$((DENY + 1))
  fi
done
echo "  50 rapid requests: $ALLOW allowed, $DENY denied (expect ~30 allowed)"

echo ""
echo "=== Done ==="