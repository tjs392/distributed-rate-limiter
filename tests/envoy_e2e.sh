#!/bin/bash
# tests/envoy_e2e.sh
# End-to-end test: Client -> Envoy -> Rate Limiter -> Backend
#
# Prerequisites:
#   1. Rate limiter cluster running:  docker compose up -d
#   2. Envoy + backend running:       docker compose -f envoy/docker-compose.yml up -d
#   3. Wait a few seconds for everything to connect

ENVOY="http://localhost:10000"
PASS=0
FAIL=0

log() { echo "[$(date '+%H:%M:%S')] $1"; }
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

envoy_request() {
    local path=$1
    shift
    curl -s -o /dev/null -w "%{http_code}" "$@" "${ENVOY}${path}"
}

send_n() {
    local n=$1
    local path=$2
    shift 2
    local ok=0
    local limited=0
    for i in $(seq 1 $n); do
        code=$(envoy_request "$path" "$@")
        if [ "$code" = "200" ]; then
            ok=$((ok + 1))
        elif [ "$code" = "429" ]; then
            limited=$((limited + 1))
        else
            echo "    unexpected status: $code on request $i"
        fi
    done
    echo "$ok $limited"
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     Envoy End-to-End Rate Limit Tests    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ============================================================
log "=== TEST 1: Envoy is up ==="

code=$(envoy_request "/health")
if [ "$code" = "200" ]; then
    pass "Envoy proxy is responding"
else
    fail "Envoy not responding (status=$code) — is it running?"
    echo "  Start with: docker compose -f envoy/docker-compose.yml up -d"
    exit 1
fi

# ============================================================
log "=== TEST 2: Backend reachable through Envoy ==="

body=$(curl -s "${ENVOY}/hello")
if echo "$body" | grep -q "Hello from backend"; then
    pass "Backend reachable through Envoy"
else
    fail "Backend not reachable (response: $body)"
fi

# ============================================================
log "=== TEST 3: Free tier gets 429 after limit (600/min) ==="

read ok limited <<< $(send_n 650 "/hello" -H "x-tier: free")
if [ "$ok" -ge 595 ] && [ "$ok" -le 615 ]; then
    pass "Free tier ~600/min via Envoy (200s=$ok 429s=$limited)"
else
    fail "Free tier wrong (200s=$ok 429s=$limited expected ~600)"
fi

# ============================================================
log "=== TEST 4: Premium tier allows more ==="

# Premium = 6000/min. Send 200 — all should pass.
read ok limited <<< $(send_n 200 "/hello" -H "x-tier: premium")
if [ "$ok" -eq 200 ] && [ "$limited" -eq 0 ]; then
    pass "Premium tier allows 200 requests (200s=$ok 429s=$limited)"
else
    fail "Premium tier wrong (200s=$ok 429s=$limited expected 200/0)"
fi

# ============================================================
log "=== TEST 5: No tier header — no rate limit ==="

read ok limited <<< $(send_n 50 "/hello")
if [ "$ok" -eq 50 ] && [ "$limited" -eq 0 ]; then
    pass "No tier header passes through (200s=$ok 429s=$limited)"
else
    fail "No tier header wrong (200s=$ok 429s=$limited expected 50/0)"
fi

# ============================================================
log "=== TEST 6: Premium + /api/search has sub-limit (600/min) ==="

read ok limited <<< $(send_n 650 "/api/search" -H "x-tier: premium")
if [ "$ok" -ge 595 ] && [ "$ok" -le 615 ]; then
    pass "Premium /api/search ~600/min (200s=$ok 429s=$limited)"
else
    fail "Premium /api/search wrong (200s=$ok 429s=$limited expected ~600)"
fi

# ============================================================
log "=== TEST 7: Ultra tier allows high volume ==="

# Ultra = 60,000/min. Send 1000 — all should pass.
read ok limited <<< $(send_n 1000 "/hello" -H "x-tier: ultra")
if [ "$ok" -eq 1000 ] && [ "$limited" -eq 0 ]; then
    pass "Ultra tier allows 1000 rapid requests (200s=$ok 429s=$limited)"
else
    fail "Ultra tier wrong (200s=$ok 429s=$limited expected 1000/0)"
fi

# ============================================================
log "=== TEST 8: 429 response works ==="

# Exhaust free tier fully (send well past the limit)
for i in $(seq 1 50); do
    curl -s -o /dev/null -H "x-tier: free" "${ENVOY}/hello"
done
code=$(envoy_request "/hello" -H "x-tier: free")
if [ "$code" = "429" ]; then
    pass "Rate limited request returns 429"
else
    fail "Expected 429 but got $code"
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
echo "Tear down with:"
echo "  docker compose -f envoy/docker-compose.yml down"
echo "  docker compose down"