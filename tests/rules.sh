#!/bin/bash
# tests/rules.sh - rules-based gRPC rate limiting tests

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

if ! command -v grpcurl &> /dev/null; then
    echo "grpcurl not installed: https://github.com/fullstorydev/grpcurl#installation"
    exit 1
fi

unique_key() { echo "$(date +%s%N)"; }

grpc_call() {
    local port=$1 json_data=$2
    grpcurl -plaintext \
        -import-path ./proto -proto rls.proto \
        -d "$json_data" -max-time 2 \
        localhost:$port \
        envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit 2>/dev/null
}

send_n() {
    local n=$1 port=$2 json_data=$3
    local ok=0 over=0
    for i in $(seq 1 $n); do
        result=$(grpc_call $port "$json_data")
        if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
            over=$((over + 1))
        else
            ok=$((ok + 1))
        fi
    done
    echo "$ok $over"
}

# ============================================================
log "TEST 1: Cluster healthy"

result=$(curl -s --max-time 2 http://localhost:8080/health)
if ! echo "$result" | grep -q "node_id"; then
    echo "  FAIL: cluster not healthy, aborting"
    exit 1
fi
assert "cluster healthy" "true"

# ============================================================
log "TEST 2: Unknown domain allows through"

TS=$(unique_key)
DATA="{\"domain\":\"unknown_domain_${TS}\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
result=$(grpc_call 50051 "$DATA")
assert "unknown domain allowed" "! echo '$result' | grep -q '\"overallCode\": \"OVER_LIMIT\"'"

# ============================================================
log "TEST 3: Unknown descriptor allows through"

TS=$(unique_key)
DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"unknown_key_${TS}\",\"value\":\"unknown_value\"}]}],\"hits_addend\":1}"
result=$(grpc_call 50051 "$DATA")
assert "unknown descriptor allowed" "! echo '$result' | grep -q '\"overallCode\": \"OVER_LIMIT\"'"

# ============================================================
log "TEST 4: Free tier limit enforced (600/min)"

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 620 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "free tier ~600/min (595-610 allowed)" "[ $ok -ge 595 ] && [ $ok -le 610 ]"

# ============================================================
log "TEST 5: Premium tier has higher limit than free"

DATA_FREE="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"free\"}]}],\"hits_addend\":1}"
DATA_PREMIUM="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"}]}],\"hits_addend\":1}"
read free_ok free_over <<< $(send_n 10 50051 "$DATA_FREE")
read premium_ok premium_over <<< $(send_n 100 50051 "$DATA_PREMIUM")
echo "  premium=$premium_ok free=$free_ok"
assert "premium allows more than free" "[ $premium_ok -gt $free_ok ]"

# ============================================================
log "TEST 6: Premium + search path hits search limit (600/min)"

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/search\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 620 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "premium+search ~600/min (595-610 allowed)" "[ $ok -ge 595 ] && [ $ok -le 610 ]"

# ============================================================
log "TEST 7: Premium without search uses premium limit"

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"premium\"},{\"key\":\"path\",\"value\":\"/api/other\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 100 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "premium non-search allows 100" "[ $ok -eq 100 ] && [ $over -eq 0 ]"

# ============================================================
log "TEST 8: Per-user limit in api domain (1000/min)"

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 1020 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "per-user ~1000/min (995-1010 allowed)" "[ $ok -ge 995 ] && [ $ok -le 1010 ]"

# ============================================================
log "TEST 9: Different users are independent"

TS=$(unique_key)
DATA_A="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_a_${TS}\"}]}],\"hits_addend\":1}"
DATA_B="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"user_b_${TS}\"}]}],\"hits_addend\":1}"
read ok_a over_a <<< $(send_n 50 50051 "$DATA_A")
read ok_b over_b <<< $(send_n 50 50051 "$DATA_B")
echo "  user_a=$ok_a user_b=$ok_b"
assert "users independent" "[ $ok_a -eq 50 ] && [ $ok_b -eq 50 ]"

# ============================================================
log "TEST 10: hits_addend counts correctly"

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"hits_${TS}\"}]}],\"hits_addend\":400}"
read ok over <<< $(send_n 5 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "hits_addend=400 (2 allowed, 3 denied)" "[ $ok -eq 2 ] && [ $over -eq 3 ]"

# ============================================================
log "TEST 11: Multiple descriptors both enforced"

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_a_${TS}\"}]},{\"entries\":[{\"key\":\"user_id\",\"value\":\"multi_b_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 1020 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "multi-descriptor ~1000/min (995-1010 allowed)" "[ $ok -ge 995 ] && [ $ok -le 1010 ]"

# ============================================================
log "TEST 12: Rules loaded on all nodes"

TS=$(unique_key)
DATA="{\"domain\":\"api\",\"descriptors\":[{\"entries\":[{\"key\":\"user_id\",\"value\":\"node_test_${TS}\"}]}],\"hits_addend\":1}"
all_pass=true
for port in 50051 50052 50053 50054 50055; do
    result=$(grpc_call $port "$DATA")
    if echo "$result" | grep -q '"overallCode": "OVER_LIMIT"'; then
        all_pass=false
    fi
done
assert "rules loaded on all 5 nodes" "$all_pass"

# ============================================================
log "TEST 13: Warning logged for unknown domain"

TS=$(unique_key)
DATA="{\"domain\":\"no_rules_domain_${TS}\",\"descriptors\":[{\"entries\":[{\"key\":\"key\",\"value\":\"val\"}]}],\"hits_addend\":1}"
grpc_call 50051 "$DATA" > /dev/null
sleep 1
assert "warning logged for unmatched domain" "docker compose logs --tail=50 2>/dev/null | grep -q 'no rule matched'"

# ============================================================
log "TEST 14: Ultra tier allows high-frequency traffic"

DATA="{\"domain\":\"my_app\",\"descriptors\":[{\"entries\":[{\"key\":\"tier\",\"value\":\"ultra\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 500 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "ultra allows 500 rapid requests" "[ $ok -eq 500 ] && [ $over -eq 0 ]"

# ============================================================
log "TEST 15: Internal domain service limit (10000/min)"

TS=$(unique_key)
DATA="{\"domain\":\"internal\",\"descriptors\":[{\"entries\":[{\"key\":\"service_name\",\"value\":\"svc_${TS}\"}]}],\"hits_addend\":1}"
read ok over <<< $(send_n 100 50051 "$DATA")
echo "  allowed=$ok denied=$over"
assert "internal allows 100 requests" "[ $ok -eq 100 ] && [ $over -eq 0 ]"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL