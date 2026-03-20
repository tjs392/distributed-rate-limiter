#!/bin/bash
# tests/envoy_e2e.sh
# End-to-end: Client -> Envoy -> Rate Limiter -> Backend
#
# Prerequisites:
#   1. Rate limiter cluster running:  docker compose up -d
#   2. Envoy + backend running:       docker compose -f envoy/docker-compose.yml up -d

ENVOY="http://localhost:10000"
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

envoy_request() {
    local path=$1
    shift
    curl -s -o /dev/null -w "%{http_code}" "$@" "${ENVOY}${path}"
}

send_n() {
    local n=$1 path=$2
    shift 2
    local ok=0 limited=0
    for i in $(seq 1 $n); do
        code=$(envoy_request "$path" "$@")
        if [ "$code" = "200" ]; then ok=$((ok + 1))
        elif [ "$code" = "429" ]; then limited=$((limited + 1))
        else echo "    unexpected status: $code on request $i"
        fi
    done
    echo "$ok $limited"
}

# ============================================================
log "TEST 1: Envoy is up"

code=$(envoy_request "/health")
if [ "$code" != "200" ]; then
    echo "  FAIL: Envoy not responding (status=$code)"
    echo "  Start with: docker compose -f envoy/docker-compose.yml up -d"
    exit 1
fi
assert "envoy proxy responding" "[ '$code' = '200' ]"

# ============================================================
log "TEST 2: Backend reachable through Envoy"

body=$(curl -s "${ENVOY}/hello")
assert "backend reachable" "echo '$body' | grep -q 'Hello from backend'"

# ============================================================
log "TEST 3: Free tier gets 429 after limit (600/min)"

read ok limited <<< $(send_n 650 "/hello" -H "x-tier: free")
echo "  200s=$ok 429s=$limited"
assert "free tier ~600/min (allowed 595-615)" "[ $ok -ge 595 ] && [ $ok -le 615 ]"

# ============================================================
log "TEST 4: Premium tier allows more"

read ok limited <<< $(send_n 200 "/hello" -H "x-tier: premium")
echo "  200s=$ok 429s=$limited"
assert "premium allows 200 requests" "[ $ok -eq 200 ] && [ $limited -eq 0 ]"

# ============================================================
log "TEST 5: No tier header -- no rate limit"

read ok limited <<< $(send_n 50 "/hello")
echo "  200s=$ok 429s=$limited"
assert "no tier passes through" "[ $ok -eq 50 ] && [ $limited -eq 0 ]"

# ============================================================
log "TEST 6: Premium + /api/search has sub-limit (600/min)"

read ok limited <<< $(send_n 650 "/api/search" -H "x-tier: premium")
echo "  200s=$ok 429s=$limited"
assert "premium /api/search ~600/min (allowed 595-615)" "[ $ok -ge 595 ] && [ $ok -le 615 ]"

# ============================================================
log "TEST 7: Ultra tier allows high volume"

read ok limited <<< $(send_n 1000 "/hello" -H "x-tier: ultra")
echo "  200s=$ok 429s=$limited"
assert "ultra allows 1000 requests" "[ $ok -eq 1000 ] && [ $limited -eq 0 ]"

# ============================================================
log "TEST 8: 429 response works"

for i in $(seq 1 50); do
    curl -s -o /dev/null -H "x-tier: free" "${ENVOY}/hello"
done
code=$(envoy_request "/hello" -H "x-tier: free")
assert "exhausted free tier returns 429" "[ '$code' = '429' ]"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL