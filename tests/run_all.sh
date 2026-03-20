#!/bin/bash
# tests/run_all.sh - run all integration tests and report results

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASSED=0
FAILED=0
RESULTS=()

log() { echo "[$(date '+%H:%M:%S')] $1"; }

TESTS=(
    "grpc_test.sh"
    "rules.sh"
    "persistence.sh"
    "lifeguard.sh"
    "envoy_e2e.sh"
    "benchmark.sh"
    "benchmark_grpc.sh"
    "stress.sh"
)

for test in "${TESTS[@]}"; do
    SCRIPT="$TESTS_DIR/$test"
    if [ ! -f "$SCRIPT" ]; then
        echo "  SKIP: $test (not found)"
        continue
    fi

    echo ""
    echo "============================================================"
    log "RUNNING: $test"
    echo "============================================================"
    echo ""

    # Clean restart between tests
    bash "$TESTS_DIR/restart.sh"

    if bash "$SCRIPT"; then
        PASSED=$((PASSED + 1))
        RESULTS+=("PASS  $test")
    else
        FAILED=$((FAILED + 1))
        RESULTS+=("FAIL  $test")
    fi
done

# ============================================================
echo ""
echo "============================================================"
echo "  TEST SUITE SUMMARY"
echo "============================================================"
echo ""
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""
echo "  $PASSED passed, $FAILED failed out of ${#RESULTS[@]} test files"
echo ""

docker compose down --timeout 2 2>/dev/null
exit $FAILED