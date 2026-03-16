#!/bin/bash
# test_lifeguard.sh
# Tests failure detection across a 5-node cluster

set -e

PORTS=(8080 8081 8082 8083 8084)
ALIVE_PORTS=(8080 8081 8083 8084)
NODE3_PORT=8082

check_request() {
    local port=$1
    local key=$2
    local limit=$3
    echo -n "node on :$port -> "
    curl -s -X POST http://localhost:$port/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$key\",\"limit\":$limit,\"hits\":1,\"window_ms\":60000}"
    echo ""
}

wait_for_log() {
    local pattern=$1
    local timeout=$2
    local elapsed=0
    echo -n "Waiting for '$pattern'..."
    while [ $elapsed -lt $timeout ]; do
        if docker compose logs 2>/dev/null | grep -qiE "$pattern"; then
            echo " found (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo " timed out after ${timeout}s"
    return 1
}

echo "=== Building and starting 5-node cluster ==="
docker compose up --build -d
sleep 5

echo ""
echo "=== All nodes healthy — sending requests ==="
for port in "${PORTS[@]}"; do
    check_request $port "user:123" 20
done

echo ""
echo "=== Health check all nodes ==="
for port in "${PORTS[@]}"; do
    echo -n "node on :$port -> "
    curl -s http://localhost:$port/health
    echo ""
done

echo ""
echo "=== SWIM logs before kill (should be all alive) ==="
docker compose logs --tail=20 | grep -iE 'suspect|dead|alive' || echo "(no state transitions yet)"

echo ""
echo "=== Killing node3 ==="
docker compose stop node3

echo ""
echo "--- Waiting for suspect transition ---"
wait_for_log "peer 3 suspect" 60

echo ""
echo "--- Waiting for dead transition ---"
wait_for_log "peer 3 declared dead" 60

echo ""
echo "=== SWIM logs after kill ==="
echo "--- Suspect transitions ---"
docker compose logs 2>/dev/null | grep -iE 'suspect' || echo "(none)"
echo "--- Dead transitions ---"
docker compose logs 2>/dev/null | grep -iE 'declared dead' || echo "(none)"

echo ""
echo "=== Checking remaining nodes still work ==="
for port in "${ALIVE_PORTS[@]}"; do
    check_request $port "user:456" 10
done

echo ""
echo "=== Node3 should be unreachable ==="
curl -s --max-time 2 http://localhost:$NODE3_PORT/health || echo "node3: unreachable (expected)"

echo ""
echo "=== Restarting node3 ==="
docker compose start node3

echo ""
echo "--- Waiting for node3 to rejoin ---"
wait_for_log "peer 3 alive" 30

echo ""
echo "=== SWIM logs after rejoin ==="
docker compose logs 2>/dev/null | grep -iE 'alive|rejoin|recovered' || echo "(none)"

echo ""
echo "=== Node3 should be back ==="
curl -s http://localhost:$NODE3_PORT/health
echo ""

echo ""
echo "=== Final check — waiting for gossip convergence ==="
# Poll until all nodes agree or we time out
CONVERGED=false
for i in $(seq 1 12); do
    sleep 5
    echo -n "Check $i: "
    COUNTS=()
    for port in "${PORTS[@]}"; do
        remaining=$(curl -s -X POST http://localhost:$port/check \
            -H "Content-Type: application/json" \
            -d '{"key":"user:456","limit":10,"hits":1,"window_ms":60000}' \
            | grep -o '"remaining":[0-9]*' | cut -d: -f2)
        COUNTS+=($remaining)
        echo -n "node:$port=$remaining "
    done
    echo ""

    # Check if all counts are equal
    FIRST=${COUNTS[0]}
    ALL_EQUAL=true
    for count in "${COUNTS[@]}"; do
        if [ "$count" != "$FIRST" ]; then
            ALL_EQUAL=false
            break
        fi
    done

    if $ALL_EQUAL; then
        echo "Converged at remaining=$FIRST"
        CONVERGED=true
        break
    fi
done

if ! $CONVERGED; then
    echo "WARNING: nodes did not converge within timeout"
fi

echo ""
echo "=== Full SWIM lifecycle log ==="
docker compose logs 2>/dev/null | grep -iE 'suspect|dead|alive|recovered' | tail -40

echo ""
echo "=== Cleanup ==="
echo "Run 'docker compose down' when done"