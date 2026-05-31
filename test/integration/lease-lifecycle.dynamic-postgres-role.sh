#!/usr/bin/env bash
# Tests: lease lifecycle, dynamic postgres role creation/revocation, reaper

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

_assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then _ok "$label"
    else _fail "$label (got='$got' want='$want')"; fi
}

# Source necessary modules
source "$LIB_DIR/crypto.sh"
source "$LIB_DIR/lease.sh"
source "$LIB_DIR/dynamic.sh"

export STRONGBOX_DATA_DIR="/tmp/strongbox-test-person3"
export _LEASES_DIR="${STRONGBOX_DATA_DIR}/leases"
rm -rf "$STRONGBOX_DATA_DIR"
mkdir -p "$_LEASES_DIR"

# Mock psql execution
MOCK_PG_LOG="${STRONGBOX_DATA_DIR}/mock_pg.log"
MOCK_PG_UNREACHABLE=0

_dynamic_pg_exec() {
    local sql="${1:?}"
    if [[ "${MOCK_PG_UNREACHABLE:-0}" == "1" ]]; then
        echo "could not connect to database server" >&2
        return 2
    fi
    echo "$sql" >> "$MOCK_PG_LOG"
    return 0
}

echo ""
echo "=== Lease Lifecycle Tests ==="

# 1. lease_create -> active state
LEASE_JSON=$(lease_create "secret/app/db" 10 100 "testuser")
_assert_eq "Lease is returned as JSON" "$(echo "$LEASE_JSON" | jq -r '.id | length')" "32"
LEASE_ID=$(echo "$LEASE_JSON" | jq -r '.id')
_assert_eq "Lease state is active" "$(echo "$LEASE_JSON" | jq -r '.state')" "active"
_assert_eq "Lease path is correct" "$(echo "$LEASE_JSON" | jq -r '.path')" "secret/app/db"

# 2. lease_renew -> extends TTL
RENEW_JSON=$(lease_renew "$LEASE_ID" '{"increment": 20}')
NEW_EXPIRES=$(echo "$RENEW_JSON" | jq -r '.expires_at')
ORIG_EXPIRES=$(echo "$LEASE_JSON" | jq -r '.expires_at')
if [[ "$NEW_EXPIRES" -gt "$ORIG_EXPIRES" ]]; then
    _ok "Lease renew extended the expiration time"
else
    _fail "Lease renew should extend the expiration time"
fi

# 3. lease_renew -> fails after max_ttl
# Mocking a lease that has reached max_ttl by editing the lease file
MOCKED_LEASE=$(cat "${_LEASES_DIR}/${LEASE_ID}" | jq '.max_expires_at = 0')
echo "$MOCKED_LEASE" > "${_LEASES_DIR}/${LEASE_ID}"
if ! lease_renew "$LEASE_ID" '{"increment": 10}' >/dev/null 2>&1; then
    _ok "Lease renew correctly fails when max_expires_at is exceeded"
else
    _fail "Lease renew should fail when max_expires_at is exceeded"
fi

# Reset lease for further testing
echo "$LEASE_JSON" > "${_LEASES_DIR}/${LEASE_ID}"

# 4. lease_revoke -> state becomes revoked
lease_revoke "$LEASE_ID" >/dev/null
UPDATED_LEASE=$(cat "${_LEASES_DIR}/${LEASE_ID}")
_assert_eq "Lease state is revoked after calling lease_revoke" "$(echo "$UPDATED_LEASE" | jq -r '.state')" "revoked"

echo ""
echo "=== Dynamic PostgreSQL Credential Tests ==="

# 5. dynamic_postgres_read -> creates role with grants and lease
STRONGBOX_LEASE_TTL=10
STRONGBOX_LEASE_MAX=100
MOCK_PG_UNREACHABLE=0
rm -f "$MOCK_PG_LOG"

RESP_JSON=$(dynamic_postgres_read "readonly")
PG_USER=$(echo "$RESP_JSON" | jq -r '.username')
PG_PASS=$(echo "$RESP_JSON" | jq -r '.password')
RESP_LEASE_ID=$(echo "$RESP_JSON" | jq -r '.lease.id')

if [[ "$PG_USER" == sb_readonly_* ]]; then
    _ok "Dynamic role username has correct prefix sb_readonly_"
else
    _fail "Dynamic role username has incorrect prefix: $PG_USER"
fi
_assert_eq "Password generated is 24 characters" "${#PG_PASS}" "24"

# Assert the correct SQL commands were executed
SQL_RUN=$(cat "$MOCK_PG_LOG")
if [[ "$SQL_RUN" == *"CREATE ROLE $PG_USER"* && "$SQL_RUN" == *"GRANT SELECT ON ALL TABLES"* ]]; then
    _ok "Correct CREATE ROLE and GRANT SQL statements executed"
else
    _fail "SQL execution mismatch: $SQL_RUN"
fi

# 6. dynamic_revoke_credential -> drops role and cleans up
rm -f "$MOCK_PG_LOG"
dynamic_revoke_credential "$PG_USER" "$RESP_LEASE_ID" >/dev/null
SQL_RUN=$(cat "$MOCK_PG_LOG")
if [[ "$SQL_RUN" == *"DROP ROLE IF EXISTS $PG_USER"* ]]; then
    _ok "DROP ROLE SQL statement executed on revocation"
else
    _fail "Revocation SQL execution mismatch: $SQL_RUN"
fi

# 7. DB-unreachable path -> state becomes revocation_pending
# Create a new dynamic credential
RESP_JSON=$(dynamic_postgres_read "readonly")
PG_USER=$(echo "$RESP_JSON" | jq -r '.username')
RESP_LEASE_ID=$(echo "$RESP_JSON" | jq -r '.lease.id')

MOCK_PG_UNREACHABLE=1
# Attempt revocation with unreachable DB
lease_revoke "$RESP_LEASE_ID" >/dev/null || true

LEASE_JSON=$(cat "${_LEASES_DIR}/${RESP_LEASE_ID}")
_assert_eq "Lease state becomes revocation_pending when DB is unreachable" "$(echo "$LEASE_JSON" | jq -r '.state')" "revocation_pending"
_assert_eq "Retry count is incremented to 1" "$(echo "$LEASE_JSON" | jq -r '.retry_count')" "1"

# 8. Reaper retry / clean up when DB returns
MOCK_PG_UNREACHABLE=0
rm -f "$MOCK_PG_LOG"

# Let's mock a scenario where handle_lease_reap runs
# First, force next_retry_at to be in the past so the reaper picks it up
LEASE_JSON=$(echo "$LEASE_JSON" | jq '.next_retry_at = 0')
echo "$LEASE_JSON" > "${_LEASES_DIR}/${RESP_LEASE_ID}"

# Mock a function response of http_respond for handle_lease_reap
http_respond() {
    echo "$2"
}

handle_lease_reap >/dev/null

LEASE_JSON=$(cat "${_LEASES_DIR}/${RESP_LEASE_ID}")
_assert_eq "Reaper successfully revokes lease once DB is reachable again" "$(echo "$LEASE_JSON" | jq -r '.state')" "revoked"

SQL_RUN=$(cat "$MOCK_PG_LOG")
if [[ "$SQL_RUN" == *"DROP ROLE IF EXISTS $PG_USER"* ]]; then
    _ok "Reaper executed the DROP ROLE SQL statement"
else
    _fail "Reaper did not drop the role: $SQL_RUN"
fi

# Clean up
rm -rf "$STRONGBOX_DATA_DIR"

echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
