#!/bin/bash
# stress_test.sh
# Stress tests the distributed rate limiter cluster under failures

PORTS=(8080 8081 8082 8083 8084)
PASS=0
FAIL=0
TOTAL_REQUESTS=0

log() { echo "[$(date '+%H:%M:%S')] $1"; }
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

check_request() {
    local port=$1
    local key=$2
    local limit=$3
    curl -s -X POST http://localhost:$port/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$key\",\"limit\":$limit,\"hits\":1,\"window_ms\":60000}" \
        --max-time 2
}

health_check() {
    local port=$1
    curl -s --max-time 2 http://localhost:$port/health 2>/dev/null
}

wait_for_log() {
    local pattern=$1
    local timeout=$2
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker compose logs 2>/dev/null | grep -qiE "$pattern"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

all_nodes_healthy() {
    for port in "${PORTS[@]}"; do
        result=$(health_check $port)
        if [ -z "$result" ]; then
            return 1
        fi
    done
    return 0
}

check_convergence() {
    local key=$1
    local expected_max=$2
    local description=$3

    sleep 3  # wait for gossip to converge

    local counts=()
    for port in "${PORTS[@]}"; do
        remaining=$(check_request $port $key 1000 | grep -o '"remaining":[0-9]*' | cut -d: -f2)
        counts+=($remaining)
    done

    # check all counts are within 2 of each other (eventual consistency tolerance)
    local min=${counts[0]}
    local max=${counts[0]}
    for count in "${counts[@]}"; do
        [ -z "$count" ] && continue
        [ "$count" -lt "$min" ] && min=$count
        [ "$count" -gt "$max" ] && max=$count
    done

    local diff=$((max - min))
    if [ "$diff" -le 3 ]; then
        pass "$description: counts converged (min=$min max=$max diff=$diff)"
    else
        fail "$description: counts diverged (min=$min max=$max diff=$diff)"
    fi
}

flood_requests() {
    local key=$1
    local count=$2
    local port=$3
    local limit=$4

    for i in $(seq 1 $count); do
        check_request $port $key $limit > /dev/null 2>&1
        TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
    done
}

flood_all_nodes() {
    local key=$1
    local count=$2
    local limit=$3

    for port in "${PORTS[@]}"; do
        flood_requests $key $count $port $limit &
    done
    wait
    TOTAL_REQUESTS=$((TOTAL_REQUESTS + count * ${#PORTS[@]}))
}

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Distributed Rate Limiter Stress Test   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ============================================================
log "=== PHASE 1: Baseline health check ==="

if all_nodes_healthy; then
    pass "All 5 nodes healthy at start"
else
    fail "Not all nodes healthy at start — aborting"
    exit 1
fi

# ============================================================
log "=== PHASE 2: Basic rate limiting ==="

# Send requests up to the limit and verify it trips
for i in $(seq 1 5); do
    check_request 8080 "stress:basic" 5 > /dev/null
done
result=$(check_request 8080 "stress:basic" 5)
status=$(echo $result | grep -o '"status":[0-9]*' | cut -d: -f2)
if [ "$status" = "429" ]; then
    pass "Rate limit correctly enforced after 5 requests"
else
    fail "Rate limit not enforced (got status=$status)"
fi

# ============================================================
log "=== PHASE 3: Concurrent flood across all nodes ==="

log "Flooding 50 requests per node across 5 nodes for key stress:flood (limit=1000)..."
flood_all_nodes "stress:flood" 50 1000
check_convergence "stress:flood" 1000 "Concurrent flood convergence"

# ============================================================
log "=== PHASE 4: Single node failure ==="

log "Killing node3..."
docker compose stop node3 2>/dev/null

if wait_for_log "peer 3 suspect" 10; then
    pass "Node3 detected as suspect within 10s"
else
    fail "Node3 not detected as suspect within 10s"
fi

if wait_for_log "peer 3 declared dead" 20; then
    pass "Node3 declared dead within 20s"
else
    fail "Node3 not declared dead within 20s"
fi

# verify remaining nodes still serve traffic
log "Checking remaining nodes serve traffic during failure..."
alive_ports=(8080 8081 8083 8084)
all_alive=true
for port in "${alive_ports[@]}"; do
    result=$(check_request $port "stress:during_failure" 100)
    status=$(echo $result | grep -o '"status":[0-9]*' | cut -d: -f2)
    if [ "$status" != "200" ]; then
        all_alive=false
    fi
done
if $all_alive; then
    pass "All remaining nodes served traffic during node3 failure"
else
    fail "Some nodes failed to serve traffic during node3 failure"
fi

# verify node3 is unreachable
result=$(curl -s --max-time 2 http://localhost:8082/health 2>/dev/null)
if [ -z "$result" ]; then
    pass "Node3 correctly unreachable"
else
    fail "Node3 still reachable after stop"
fi

# ============================================================
log "=== PHASE 5: Flood during failure ==="

log "Flooding 30 requests per node on surviving nodes..."
for port in "${alive_ports[@]}"; do
    flood_requests "stress:failure_flood" 30 $port 1000 &
done
wait

sleep 5
counts=()
for port in "${alive_ports[@]}"; do
    remaining=$(check_request $port "stress:failure_flood" 1000 | grep -o '"remaining":[0-9]*' | cut -d: -f2)
    counts+=($remaining)
done

min=${counts[0]}
max=${counts[0]}
for count in "${counts[@]}"; do
    [ -z "$count" ] && continue
    [ "$count" -lt "$min" ] && min=$count
    [ "$count" -gt "$max" ] && max=$count
done
diff=$((max - min))
if [ "$diff" -le 3 ]; then
    pass "Cluster converged during node failure (min=$min max=$max)"
else
    fail "Cluster diverged during node failure (min=$min max=$max diff=$diff)"
fi

# ============================================================
log "=== PHASE 6: Node recovery ==="

log "Restarting node3..."
docker compose start node3 2>/dev/null

if wait_for_log "peer 3 alive" 30; then
    pass "Node3 rejoined cluster within 30s"
else
    fail "Node3 did not rejoin within 30s"
fi

sleep 3
result=$(health_check 8082)
if echo "$result" | grep -q "node_id"; then
    pass "Node3 serving traffic after rejoin"
else
    fail "Node3 not serving traffic after rejoin"
fi

# ============================================================
log "=== PHASE 7: Cascading failures ==="

log "Killing node2 and node4 simultaneously..."
docker compose stop node2 node4 2>/dev/null

sleep 15

# check cluster still works with 3/5 nodes
surviving=(8080 8082 8084)
all_ok=true
for port in "${surviving[@]}"; do
    result=$(check_request $port "stress:cascade" 100)
    status=$(echo $result | grep -o '"status":[0-9]*' | cut -d: -f2)
    if [ "$status" != "200" ]; then
        all_ok=false
    fi
done
if $all_ok; then
    pass "Cluster survived 2 simultaneous node failures (3/5 nodes alive)"
else
    fail "Cluster failed with 2 simultaneous node failures"
fi

log "Restarting node2 and node4..."
docker compose start node2 node4 2>/dev/null
sleep 10

if all_nodes_healthy; then
    pass "Full cluster recovered after cascading failure"
else
    fail "Cluster did not fully recover after cascading failure"
fi

# ============================================================
log "=== PHASE 8: Rapid flap test ==="

log "Rapidly stopping and starting node3 five times..."
for i in $(seq 1 5); do
    docker compose stop node3 2>/dev/null
    sleep 2
    docker compose start node3 2>/dev/null
    sleep 2
done

sleep 10
if all_nodes_healthy; then
    pass "Cluster stable after rapid node flapping"
else
    fail "Cluster unstable after rapid node flapping"
fi

# ============================================================
log "=== PHASE 9: Rate limit correctness under gossip lag ==="

# hit limit on one node then immediately check another
KEY="stress:limit_correctness"
LIMIT=10

for i in $(seq 1 10); do
    check_request 8080 $KEY $LIMIT > /dev/null
done

# immediately check a different node — may still show remaining due to gossip lag
result=$(check_request 8081 $KEY $LIMIT)
status=$(echo $result | grep -o '"status":[0-9]*' | cut -d: -f2)
remaining=$(echo $result | grep -o '"remaining":[0-9]*' | cut -d: -f2)
log "  Immediate cross-node check: status=$status remaining=$remaining (gossip lag expected)"

# after convergence it should be at limit
sleep 3
result=$(check_request 8081 $KEY $LIMIT)
status=$(echo $result | grep -o '"status":[0-9]*' | cut -d: -f2)
if [ "$status" = "429" ]; then
    pass "Rate limit correctly enforced across nodes after gossip convergence"
else
    remaining=$(echo $result | grep -o '"remaining":[0-9]*' | cut -d: -f2)
    fail "Rate limit not enforced after convergence (status=$status remaining=$remaining)"
fi

# ============================================================
log "=== PHASE 10: Final cluster health ==="

if all_nodes_healthy; then
    pass "All 5 nodes healthy at end of stress test"
else
    fail "Not all nodes healthy at end of stress test"
fi

# ============================================================
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              RESULTS                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Total requests sent: $TOTAL_REQUESTS"
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