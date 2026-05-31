#!/usr/bin/env bash
# Tests: leader election, sealed 503, follower redirect, partition behaviour

set -euo pipefail

# Robust curl override to retry transient connection errors from lightweight netcat loops restarting
curl() {
    local max_tries=5
    local try=1
    while (( try <= max_tries )); do
        local out err code
        out=$(command curl "$@" 2>/tmp/curl-err) && code=0 || code=$?
        if (( code == 0 )); then
            printf '%s' "$out"
            return 0
        elif (( code == 7 || code == 56 || code == 52 )); then
            sleep 0.1
            (( try++ ))
        else
            cat /tmp/curl-err >&2
            return "$code"
        fi
    done
    command curl "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

_assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then _ok "$label"
    else _fail "$label (got='$got' want='$want')"; fi
}

_assert_ne() {
    local label="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then _ok "$label"
    else _fail "$label (values should differ but both='$a')"; fi
}

TEST_DIR="/tmp/strongbox-cluster-test"
rm -rf "$TEST_DIR"
rm -f /tmp/strongbox-* 2>/dev/null || true
mkdir -p "$TEST_DIR/node1" "$TEST_DIR/node2" "$TEST_DIR/node3"

_wait_for_port() {
    local port="$1"
    for i in {1..40}; do
        if curl -s "http://127.0.0.1:$port/v1/sys/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

echo "=== Starting 3-Node StrongBox Cluster ==="

# Start Node 1
STRONGBOX_NODE_ID=node1 \
STRONGBOX_PORT=8201 \
STRONGBOX_SHAMIR_K=2 \
STRONGBOX_PEERS="127.0.0.1:8202,127.0.0.1:8203" \
STRONGBOX_NODE_ADDR="127.0.0.1:8201" \
STRONGBOX_DATA_DIR="$TEST_DIR/node1" \
STRONGBOX_AUDIT_LOG="$TEST_DIR/node1/audit.log" \
bash "$SCRIPT_DIR/../../bin/strongbox" > "$TEST_DIR/node1.log" 2>&1 &
NODE1_PID=$!

# Start Node 2
STRONGBOX_NODE_ID=node2 \
STRONGBOX_PORT=8202 \
STRONGBOX_SHAMIR_K=2 \
STRONGBOX_PEERS="127.0.0.1:8201,127.0.0.1:8203" \
STRONGBOX_NODE_ADDR="127.0.0.1:8202" \
STRONGBOX_DATA_DIR="$TEST_DIR/node2" \
STRONGBOX_AUDIT_LOG="$TEST_DIR/node2/audit.log" \
bash "$SCRIPT_DIR/../../bin/strongbox" > "$TEST_DIR/node2.log" 2>&1 &
NODE2_PID=$!

# Start Node 3
STRONGBOX_NODE_ID=node3 \
STRONGBOX_PORT=8203 \
STRONGBOX_SHAMIR_K=2 \
STRONGBOX_PEERS="127.0.0.1:8201,127.0.0.1:8202" \
STRONGBOX_NODE_ADDR="127.0.0.1:8203" \
STRONGBOX_DATA_DIR="$TEST_DIR/node3" \
STRONGBOX_AUDIT_LOG="$TEST_DIR/node3/audit.log" \
bash "$SCRIPT_DIR/../../bin/strongbox" > "$TEST_DIR/node3.log" 2>&1 &
NODE3_PID=$!

_cleanup() {
    echo "=== Cleaning up Cluster ==="
    kill "$NODE1_PID" "$NODE2_PID" "$NODE3_PID" 2>/dev/null || true
    wait "$NODE1_PID" "$NODE2_PID" "$NODE3_PID" 2>/dev/null || true
    # rm -rf "$TEST_DIR"
}
trap _cleanup EXIT

_wait_for_port 8201 || {
    _fail "Node 1 failed to start"
    echo "=== Node 1 Log ==="
    cat "$TEST_DIR/node1.log" || true
    echo "=== Node 2 Log ==="
    cat "$TEST_DIR/node2.log" || true
    echo "=== Node 3 Log ==="
    cat "$TEST_DIR/node3.log" || true
    exit 1
}
_wait_for_port 8202 || {
    _fail "Node 2 failed to start"
    echo "=== Node 2 Log ==="
    cat "$TEST_DIR/node2.log" || true
    exit 1
}
_wait_for_port 8203 || {
    _fail "Node 3 failed to start"
    echo "=== Node 3 Log ==="
    cat "$TEST_DIR/node3.log" || true
    exit 1
}

echo ""
echo "=== Test 1: Cluster Sealed State on Boot ==="
SEALED1=$(curl -s "http://127.0.0.1:8201/v1/sys/health" | jq -r '.sealed')
SEALED2=$(curl -s "http://127.0.0.1:8202/v1/sys/health" | jq -r '.sealed')
SEALED3=$(curl -s "http://127.0.0.1:8203/v1/sys/health" | jq -r '.sealed')

_assert_eq "Node 1 is sealed on boot" "$SEALED1" "true"
_assert_eq "Node 2 is sealed on boot" "$SEALED2" "true"
_assert_eq "Node 3 is sealed on boot" "$SEALED3" "true"

echo ""
echo "=== Test 2: Sealed Nodes Return 503 Service Unavailable ==="
RESP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8201/v1/secrets/foo")
_assert_eq "Sealed node returns 503 for secrets GET" "$RESP_CODE" "503"

echo ""
echo "=== Test 3: Initialize Node 1 ==="
INIT_RESP=$(curl -s -X POST "http://127.0.0.1:8201/v1/sys/init")
ROOT_TOKEN=$(echo "$INIT_RESP" | jq -r '.root_token')
SHARE1=$(echo "$INIT_RESP" | jq -r '.shares[0]')
SHARE2=$(echo "$INIT_RESP" | jq -r '.shares[1]')
SHARE3=$(echo "$INIT_RESP" | jq -r '.shares[2]')

_assert_ne "Root token generated" "$ROOT_TOKEN" "null"
_assert_ne "Share 1 is populated" "$SHARE1" "null"

echo ""
echo "=== Test 4: Unseal Nodes with Shares ==="
# Submit share 1 and share 2 to Node 1
curl -s -X POST "http://127.0.0.1:8201/v1/sys/unseal" -d "{\"share\":\"$SHARE1\"}" >/dev/null
UNSEAL1=$(curl -s -X POST "http://127.0.0.1:8201/v1/sys/unseal" -d "{\"share\":\"$SHARE2\"}" | jq -r '.sealed')
_assert_eq "Node 1 unsealed" "$UNSEAL1" "false"

# Submit share 1 and share 2 to Node 2
curl -s -X POST "http://127.0.0.1:8202/v1/sys/unseal" -d "{\"share\":\"$SHARE1\"}" >/dev/null
UNSEAL2=$(curl -s -X POST "http://127.0.0.1:8202/v1/sys/unseal" -d "{\"share\":\"$SHARE2\"}" | jq -r '.sealed')
_assert_eq "Node 2 unsealed" "$UNSEAL2" "false"

# Submit share 1 and share 2 to Node 3
curl -s -X POST "http://127.0.0.1:8203/v1/sys/unseal" -d "{\"share\":\"$SHARE1\"}" >/dev/null
UNSEAL3=$(curl -s -X POST "http://127.0.0.1:8203/v1/sys/unseal" -d "{\"share\":\"$SHARE2\"}" | jq -r '.sealed')
_assert_eq "Node 3 unsealed" "$UNSEAL3" "false"

echo ""
echo "=== Test 5: Leader Election ==="
sleep 3.5

LEADER_PORT=""
FOLLOWER_PORTS=()
for port in 8201 8202 8203; do
    IS_LEADER=$(curl -s "http://127.0.0.1:$port/v1/sys/health" | jq -r '.leader')
    if [[ "$IS_LEADER" == "true" ]]; then
        LEADER_PORT="$port"
    else
        FOLLOWER_PORTS+=("$port")
    fi
done

_assert_ne "Leader successfully elected" "$LEADER_PORT" ""
_assert_eq "Exactly two followers exist" "${#FOLLOWER_PORTS[@]}" "2"

echo ""
echo "=== Test 6: Write via Leader and Read via Follower ==="
WRITE_RESP=$(curl -s -X PUT "http://127.0.0.1:$LEADER_PORT/v1/secrets/app/db" \
    -H "Authorization: Bearer $ROOT_TOKEN" \
    -d '{"data":{"password":"clustersecret"}}')
_assert_eq "Write to leader returns version 1" "$(echo "$WRITE_RESP" | jq -r '.version')" "1"

# Allow replication heartbeat to sync state
sleep 0.25

FOLLOWER_PORT="${FOLLOWER_PORTS[0]}"
READ_RESP=$(curl -s "http://127.0.0.1:$FOLLOWER_PORT/v1/secrets/app/db" \
    -H "Authorization: Bearer $ROOT_TOKEN")
_assert_eq "Read from follower recovers correct secret" "$(echo "$READ_RESP" | jq -r '.data.password')" "clustersecret"

echo ""
echo "=== Test 7: Follower Redirect (307) on Follower Write ==="
REDIRECT_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://127.0.0.1:$FOLLOWER_PORT/v1/secrets/app/db" \
    -H "Authorization: Bearer $ROOT_TOKEN" \
    -d '{"data":{"password":"newsecret"}}')
_assert_eq "Write to follower returns 307 redirect status code" "$REDIRECT_RESP" "307"

echo ""
echo "=== Test 8: Failover - Terminate Current Leader ==="
echo "Terminating leader on port $LEADER_PORT..."
if [[ "$LEADER_PORT" == "8201" ]]; then kill "$NODE1_PID"; wait "$NODE1_PID" 2>/dev/null || true
elif [[ "$LEADER_PORT" == "8202" ]]; then kill "$NODE2_PID"; wait "$NODE2_PID" 2>/dev/null || true
else kill "$NODE3_PID"; wait "$NODE3_PID" 2>/dev/null || true; fi

# Allow reelection time
sleep 3.5

NEW_LEADER_PORT=""
for port in "${FOLLOWER_PORTS[@]}"; do
    IS_LEADER=$(curl -s "http://127.0.0.1:$port/v1/sys/health" | jq -r '.leader' 2>/dev/null || echo "false")
    if [[ "$IS_LEADER" == "true" ]]; then
        NEW_LEADER_PORT="$port"
    fi
done

_assert_ne "New leader elected after old leader termination" "$NEW_LEADER_PORT" ""
_assert_ne "New leader port differs from old leader port" "$NEW_LEADER_PORT" "$LEADER_PORT"

echo ""
echo "=== Test 9: Write Works on the New Leader ==="
WRITE_RESP2=$(curl -s -X PUT "http://127.0.0.1:$NEW_LEADER_PORT/v1/secrets/app/api" \
    -H "Authorization: Bearer $ROOT_TOKEN" \
    -d '{"data":{"apikey":"fresh_api_key"}}')
_assert_eq "Write to new leader succeeds" "$(echo "$WRITE_RESP2" | jq -r '.version' 2>/dev/null)" "1"

echo ""
echo "=== Test 10: Partition Behavior - Stop Follower to Lose Quorum ==="
# Find the remaining follower
OTHER_FOLLOWER_PORT=""
for port in "${FOLLOWER_PORTS[@]}"; do
    if [[ "$port" != "$NEW_LEADER_PORT" ]]; then
        OTHER_FOLLOWER_PORT="$port"
    fi
done

echo "Terminating second node on port $OTHER_FOLLOWER_PORT to drop active count below quorum..."
if [[ "$OTHER_FOLLOWER_PORT" == "8201" ]]; then kill "$NODE1_PID"; wait "$NODE1_PID" 2>/dev/null || true
elif [[ "$OTHER_FOLLOWER_PORT" == "8202" ]]; then kill "$NODE2_PID"; wait "$NODE2_PID" 2>/dev/null || true
else kill "$NODE3_PID"; wait "$NODE3_PID" 2>/dev/null || true; fi

# Wait for node to detect minority partition and step down
sleep 1.5

IS_LEADER_NOW=$(curl -s "http://127.0.0.1:$NEW_LEADER_PORT/v1/sys/health" | jq -r '.leader' 2>/dev/null || echo "false")
_assert_eq "Sole remaining node has stepped down from being leader" "$IS_LEADER_NOW" "false"

WRITE_RESP3_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://127.0.0.1:$NEW_LEADER_PORT/v1/secrets/app/api" \
    -H "Authorization: Bearer $ROOT_TOKEN" \
    -d '{"data":{"apikey":"broken"}}')
_assert_eq "Write request is refused with 307 because no leader exists" "$WRITE_RESP3_CODE" "307"

echo ""
echo "=== Summary ==="
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
