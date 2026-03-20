#!/bin/bash
# tests/lifeguard.sh - SWIM+Lifeguard failure detection tests

PORTS=(8080 8081 8082 8083 8084)
ALIVE_PORTS=(8080 8081 8083 8084)
NODE3_PORT=8082
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

check_request() {
    local port=$1 key=$2 limit=$3
    curl -s -X POST http://localhost:$port/check \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$key\",\"limit\":$limit,\"hits\":1,\"window_ms\":60000}"
}

wait_for_log() {
    local pattern=$1 timeout=$2 elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker compose logs 2>/dev/null | grep -qiE "$pattern"; then
            echo "  found '$pattern' (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "  timed out waiting for '$pattern' (${timeout}s)"
    return 1
}

# ============================================================
log "Starting 5-node cluster"
docker compose up --build -d
sleep 5

# ============================================================
log "TEST 1: All nodes healthy"

all_healthy=true
for port in "${PORTS[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$port/health)
    if [ "$code" != "200" ]; then all_healthy=false; fi
done
assert "all 5 nodes responding" "$all_healthy"

# ============================================================
log "TEST 2: Requests work across cluster"

for port in "${PORTS[@]}"; do
    RESP=$(check_request $port "lifeguard:test" 100)
    echo "  :$port -> $RESP"
done

# ============================================================
log "TEST 3: Kill node3, detect suspect"

docker compose stop node3
wait_for_log "peer 3 suspect" 60
assert "node3 marked suspect" "docker compose logs 2>/dev/null | grep -qiE 'peer 3 suspect'"

# ============================================================
log "TEST 4: Node3 declared dead"

wait_for_log "peer 3 declared dead" 60
assert "node3 declared dead" "docker compose logs 2>/dev/null | grep -qiE 'peer 3 declared dead'"

# ============================================================
log "TEST 5: Remaining nodes still work"

for port in "${ALIVE_PORTS[@]}"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:$port/check \
        -H "Content-Type: application/json" \
        -d '{"key":"lifeguard:alive","limit":100,"hits":1,"window_ms":60000}')
    assert "node :$port still serving" "[ '$code' = '200' ]"
done

# ============================================================
log "TEST 6: Node3 unreachable"

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://localhost:$NODE3_PORT/health)
assert "node3 unreachable" "[ '$code' != '200' ]"

# ============================================================
log "TEST 7: Restart node3, rejoin cluster"

docker compose start node3
sleep 3
code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$NODE3_PORT/health)
assert "node3 responding after restart" "[ '$code' = '200' ]"

wait_for_log "peer 3 alive" 30
assert "node3 marked alive after rejoin" "docker compose logs 2>/dev/null | grep -qiE 'peer 3 alive'"

# ============================================================
log "TEST 8: Gossip convergence after rejoin"

CONV_KEY="lifeguard:conv_$(date +%s)"
check_request 8080 "$CONV_KEY" 100000 > /dev/null
sleep 2

converged=false
for i in $(seq 1 12); do
    sleep 5
    counts=()
    for port in "${PORTS[@]}"; do
        remaining=$(check_request $port "$CONV_KEY" 100000 2>/dev/null \
            | grep -o '"remaining":[0-9]*' | cut -d: -f2)
        counts+=($remaining)
    done

    min=${counts[0]} max=${counts[0]}
    for c in "${counts[@]}"; do
        [ "$c" -lt "$min" ] && min=$c
        [ "$c" -gt "$max" ] && max=$c
    done
    spread=$((max - min))
    echo "  check $i: spread=$spread (min=$min max=$max)"

    if [ $spread -le 5 ]; then
        echo "  converged (spread <= 5)"
        converged=true
        break
    fi
done
assert "cluster converged after rejoin" "$converged"

# ============================================================
log "SWIM lifecycle log (last 30 lines)"
docker compose logs 2>/dev/null | grep -iE 'suspect|dead|alive' | tail -30

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Run 'docker compose down' when done"
exit $FAIL