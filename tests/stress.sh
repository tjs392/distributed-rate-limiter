#!/bin/bash
# tests/stress.sh
# Brutal stress test for the distributed rate limiter
#
# Covers:
#   1. Throughput — max rps through Envoy and direct gRPC
#   2. Accuracy — are limits enforced correctly under heavy concurrency?
#   3. Multi-node consistency — load balanced across all 5 nodes
#   4. Latency — p50/p95/p99 profiling
#   5. Ultra tier — high-frequency (1000/sec) sustained load
#
# Prerequisites:
#   - hey:     go install github.com/rakyll/hey@latest
#   - ghz:     go install github.com/bojand/ghz/cmd/ghz@latest
#   - grpcurl: go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
#   - jq:      apt install jq
#   - Rate limiter cluster running: docker compose up -d
#   - Envoy running: docker compose -f envoy/docker-compose.yml up -d

set -euo pipefail

ENVOY="http://localhost:10000"
PROTO_PATH="./proto/rls.proto"
GRPC_METHOD="envoy.service.ratelimit.v3.RateLimitService.ShouldRateLimit"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

section() {
    echo ""
    echo -e "${YELLOW}--- $1 ---${NC}"
    echo ""
}

check_deps() {
    local missing=()
    command -v hey &>/dev/null || missing+=("hey (go install github.com/rakyll/hey@latest)")
    command -v ghz &>/dev/null || missing+=("ghz (go install github.com/bojand/ghz/cmd/ghz@latest)")
    command -v grpcurl &>/dev/null || missing+=("grpcurl (go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest)")
    command -v jq &>/dev/null || missing+=("jq (apt install jq)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing dependencies:${NC}"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

check_services() {
    local ok=true
    curl -s --max-time 2 "$ENVOY/hello" -o /dev/null || { echo -e "${RED}Envoy not responding on :10000${NC}"; ok=false; }
    curl -s --max-time 2 "http://localhost:8080/health" -o /dev/null || { echo -e "${RED}Rate limiter not responding on :8080${NC}"; ok=false; }
    $ok || { echo "Start services first. See script header for instructions."; exit 1; }
    echo -e "${GREEN}All services healthy.${NC}"
}

restart_all() {
    echo "  Restarting cluster for clean counters..."
    docker compose down --timeout 2 2>/dev/null
    docker compose up -d 2>/dev/null
    sleep 6
    docker compose -f envoy/docker-compose.yml down --timeout 2 2>/dev/null
    docker compose -f envoy/docker-compose.yml up -d 2>/dev/null
    sleep 3
}

restart_cluster_only() {
    echo "  Restarting rate limiter cluster..."
    docker compose down --timeout 2 2>/dev/null
    docker compose up -d 2>/dev/null
    sleep 6
}

unique_key() {
    echo "stress_$(date +%s%N)_${RANDOM}"
}

# Parse hey output for status code counts
# hey format: "  [200]	6000 responses"
parse_hey_status() {
    local output="$1"
    local code=$2
    echo "$output" | grep "\[$code\]" | awk '{print $2}' || echo "0"
}

# Run hey and capture output
run_hey() {
    hey "$@" 2>&1
}

# ════════════════════════════════════════════════════════════════
# Phase 1: Raw Throughput
# ════════════════════════════════════════════════════════════════
phase_throughput() {
    header "PHASE 1: RAW THROUGHPUT"

    section "1a: Envoy proxy throughput — no rate limit (100k requests, 200 concurrent)"
    local out_1a
    out_1a=$(run_hey -n 100000 -c 200 -q 0 "$ENVOY/hello")
    echo "$out_1a"
    rps_passthrough=$(echo "$out_1a" | grep "Requests/sec" | awk '{print $2}')

    section "1b: Envoy + rate limiting — premium tier (100k requests, 200 concurrent)"
    local out_1b
    out_1b=$(run_hey -n 100000 -c 200 -q 0 -H "x-tier: premium" "$ENVOY/hello")
    echo "$out_1b"
    rps_ratelimited=$(echo "$out_1b" | grep "Requests/sec" | awk '{print $2}')

    section "1c: Envoy + rate limiting — ultra tier (100k requests, 500 concurrent)"
    local out_1c
    out_1c=$(run_hey -n 100000 -c 500 -q 0 -H "x-tier: ultra" "$ENVOY/hello")
    echo "$out_1c"
    rps_ultra=$(echo "$out_1c" | grep "Requests/sec" | awk '{print $2}')

    section "1d: Direct gRPC throughput (100k requests, 200 concurrent)"
    TS=$(unique_key)
    ghz --insecure \
        --proto $PROTO_PATH \
        --call $GRPC_METHOD \
        -d "{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
        --total 100000 \
        --concurrency 200 \
        localhost:50051

    section "1e: Direct gRPC throughput — max concurrency (100k requests, 500 concurrent)"
    TS=$(unique_key)
    ghz --insecure \
        --proto $PROTO_PATH \
        --call $GRPC_METHOD \
        -d "{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
        --total 100000 \
        --concurrency 500 \
        localhost:50051

    echo ""
    echo -e "  ${BOLD}Throughput Summary:${NC}"
    printf "    %-40s %s rps\n" "envoy_passthrough" "${rps_passthrough:-?}"
    printf "    %-40s %s rps\n" "envoy_ratelimited (premium)" "${rps_ratelimited:-?}"
    printf "    %-40s %s rps\n" "envoy_ultra" "${rps_ultra:-?}"
}

# ════════════════════════════════════════════════════════════════
# Phase 2: Accuracy Under Concurrency
# ════════════════════════════════════════════════════════════════
phase_accuracy() {
    header "PHASE 2: ACCURACY UNDER CONCURRENCY"
    restart_all

    # --- 2a: Free tier accuracy (limit=600/min) ---
    section "2a: Free tier accuracy — 100 concurrent, 2000 requests (limit=600/min)"

    local out_2a
    out_2a=$(run_hey -n 2000 -c 100 -q 0 -H "x-tier: free" "$ENVOY/hello")
    echo "$out_2a"

    ok_count=$(parse_hey_status "$out_2a" 200)
    limited_count=$(parse_hey_status "$out_2a" 429)
    echo ""
    echo -e "  Free tier (limit=600/min): ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"

    if [ "$ok_count" = "600" ]; then
        echo -e "  ${GREEN}✓ PERFECT — exactly 600 allowed${NC}"
    elif [ "$ok_count" != "0" ] && [ "$ok_count" -le 650 ] 2>/dev/null; then
        echo -e "  ${YELLOW}~ ACCEPTABLE — slight over-admit ($ok_count vs 600) due to distributed counting${NC}"
    elif [ "$ok_count" != "0" ] 2>/dev/null; then
        echo -e "  ${RED}✗ OFF — $ok_count allowed, expected ~600${NC}"
    fi

    # --- 2b: Premium tier accuracy (limit=6000/min) ---
    section "2b: Premium tier accuracy — 200 concurrent, 10000 requests (limit=6000/min)"

    local out_2b
    out_2b=$(run_hey -n 10000 -c 200 -q 0 -H "x-tier: premium" "$ENVOY/hello")
    echo "$out_2b"

    ok_count=$(parse_hey_status "$out_2b" 200)
    limited_count=$(parse_hey_status "$out_2b" 429)
    echo ""
    echo -e "  Premium tier (limit=6000/min): ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"

    if [ "$ok_count" -ge 5800 ] && [ "$ok_count" -le 6200 ] 2>/dev/null; then
        echo -e "  ${GREEN}✓ GOOD — within 3% of limit ($ok_count vs 6000)${NC}"
    else
        echo -e "  ${YELLOW}~ OFF — $ok_count allowed vs 6000 limit${NC}"
    fi

    # --- 2c: Per-user accuracy via gRPC (limit=1000/min) ---
    section "2c: Per-user accuracy — 100 concurrent, 1500 requests (limit=1000/min)"

    TS=$(unique_key)
    ghz --insecure \
        --proto $PROTO_PATH \
        --call $GRPC_METHOD \
        -d "{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
        --total 1500 \
        --concurrency 100 \
        localhost:50051

    echo ""
    echo "  Probing final state..."
    grpcurl -plaintext \
        -import-path ./proto -proto rls.proto \
        -d "{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":0}" \
        localhost:50051 $GRPC_METHOD 2>/dev/null || true

    # --- 2d: Search sub-limit accuracy (limit=600/min under premium) ---
    section "2d: Premium search sub-limit — 100 concurrent, 1000 requests (limit=600/min)"

    local out_2d
    out_2d=$(run_hey -n 1000 -c 100 -q 0 -H "x-tier: premium" "$ENVOY/api/search")
    echo "$out_2d"

    ok_count=$(parse_hey_status "$out_2d" 200)
    limited_count=$(parse_hey_status "$out_2d" 429)
    echo ""
    echo -e "  Premium /api/search (limit=600/min): ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"
}

# ════════════════════════════════════════════════════════════════
# Phase 3: Multi-Node Consistency
# ════════════════════════════════════════════════════════════════
phase_multinode() {
    header "PHASE 3: MULTI-NODE CONSISTENCY"
    restart_cluster_only

    section "3a: Same key across 5 nodes — 2000 requests per node (limit=1000/min)"

    TS=$(unique_key)
    DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":1}"

    for port in 50051 50052 50053 50054 50055; do
        ghz --insecure \
            --proto $PROTO_PATH \
            --call $GRPC_METHOD \
            -d "$DATA" \
            --total 2000 \
            --concurrency 100 \
            localhost:$port \
            2>&1 | grep -E "Count:|Requests/sec" | sed "s/^/  Port $port: /"
    done

    echo ""
    echo "  Waiting 5s for gossip convergence..."
    sleep 5

    echo ""
    echo "  Final state check (limit=1000/min, sent 10000 total across 5 nodes):"
    for port in 50051 50052 50053 50054 50055; do
        result=$(grpcurl -plaintext \
            -import-path ./proto -proto rls.proto \
            -d "$DATA" \
            localhost:$port $GRPC_METHOD 2>/dev/null)
        code=$(echo "$result" | jq -r '.overallCode // "OK"' 2>/dev/null || echo "?")
        remaining=$(echo "$result" | jq -r '.statuses[0].limitRemaining // "?"' 2>/dev/null || echo "?")
        echo "    Node :$port → overallCode=$code remaining=$remaining"
    done

    section "3b: 100 unique users, 200 requests each, spread across nodes"

    for i in $(seq 1 100); do
        TS=$(unique_key)
        port=$((50051 + (i % 5)))
        DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"$TS\"}]}],\"hits_addend\":1}"

        ghz --insecure \
            --proto $PROTO_PATH \
            --call $GRPC_METHOD \
            -d "$DATA" \
            --total 200 \
            --concurrency 20 \
            localhost:$port \
            2>/dev/null > /dev/null
    done

    echo "  Sent 20,000 total requests (100 users × 200 requests) across 5 nodes"
}

# ════════════════════════════════════════════════════════════════
# Phase 4: Latency Profiling
# ════════════════════════════════════════════════════════════════
phase_latency() {
    header "PHASE 4: LATENCY PROFILING"
    restart_all

    section "4a: Envoy end-to-end — ultra tier (50k requests, 100 concurrent)"
    run_hey -n 50000 -c 100 -q 0 -H "x-tier: ultra" "$ENVOY/hello"

    section "4b: Direct gRPC (50k requests, 100 concurrent)"
    TS=$(unique_key)
    ghz --insecure \
        --proto $PROTO_PATH \
        --call $GRPC_METHOD \
        -d "{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
        --total 50000 \
        --concurrency 100 \
        localhost:50051

    section "4c: Envoy baseline — no rate limiting (50k requests, 100 concurrent)"
    run_hey -n 50000 -c 100 -q 0 "$ENVOY/hello"

    section "4d: Latency under increasing concurrency (direct gRPC)"
    for conc in 10 50 100 200 500 1000; do
        TS=$(unique_key)
        echo -e "\n  ${BOLD}Concurrency: $conc${NC}"
        ghz --insecure \
            --proto $PROTO_PATH \
            --call $GRPC_METHOD \
            -d "{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"$TS\"}]}],\"hits_addend\":1}" \
            --total 10000 \
            --concurrency $conc \
            localhost:50051 \
            2>&1 | grep -E "Average|Fastest|Slowest|50th|95th|99th|Requests/sec" | sed 's/^/    /'
    done
}

# ════════════════════════════════════════════════════════════════
# Phase 5: Ultra Tier — High-Frequency Sustained Load
# ════════════════════════════════════════════════════════════════
phase_ultra() {
    header "PHASE 5: ULTRA TIER — HIGH-FREQUENCY SUSTAINED LOAD"
    restart_all

    section "5a: Sustained 1000 rps through Envoy for 30 seconds (ultra tier, 60k/min limit)"
    local out_5a
    out_5a=$(run_hey -n 30000 -c 100 -q 1000 -H "x-tier: ultra" "$ENVOY/hello")
    echo "$out_5a"

    ok_count=$(parse_hey_status "$out_5a" 200)
    limited_count=$(parse_hey_status "$out_5a" 429)
    echo ""
    echo -e "  Ultra sustained 1000rps: ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"
    if [ "$limited_count" = "0" ] || [ -z "$limited_count" ]; then
        echo -e "  ${GREEN}✓ All requests within 60k/min limit${NC}"
    fi

    section "5b: Burst beyond ultra limit — 100k requests, max speed (60k/min limit)"
    local out_5b
    out_5b=$(run_hey -n 100000 -c 500 -q 0 -H "x-tier: ultra" "$ENVOY/hello")
    echo "$out_5b"

    ok_count=$(parse_hey_status "$out_5b" 200)
    limited_count=$(parse_hey_status "$out_5b" 429)
    echo ""
    echo -e "  Ultra burst: ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"
    echo -e "  Expected ~60k allowed, rest 429"

    section "5c: Ultra search sub-limit — 10k requests at /api/search (6000/min limit)"
    local out_5c
    out_5c=$(run_hey -n 10000 -c 200 -q 0 -H "x-tier: ultra" "$ENVOY/api/search")
    echo "$out_5c"

    ok_count=$(parse_hey_status "$out_5c" 200)
    limited_count=$(parse_hey_status "$out_5c" 429)
    echo ""
    echo -e "  Ultra /api/search: ${BOLD}200s=${ok_count} 429s=${limited_count}${NC}"
    echo -e "  Expected ~6000 allowed, rest 429"

    section "5d: Direct gRPC — simulated HFT feed (100k requests, 500 concurrent)"
    TS=$(unique_key)
    ghz --insecure \
        --proto $PROTO_PATH \
        --call $GRPC_METHOD \
        -d "{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"ultra\"}]}],\"hits_addend\":1}" \
        --total 100000 \
        --concurrency 500 \
        localhost:50051
}

# ════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          DISTRIBUTED RATE LIMITER STRESS TEST           ║${NC}"
echo -e "${BOLD}║              ~500k+ requests across 5 phases            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

check_deps
check_services

START=$(date +%s)

phase_throughput
phase_accuracy
phase_multinode
phase_latency
phase_ultra

echo ""
header "DONE"
END=$(date +%s)
ELAPSED=$((END - START))
echo -e "  Total time: ${BOLD}${ELAPSED}s${NC}"
echo ""