#!/usr/bin/env bash
# test/integration/test_person3.sh
# OWNER: Person 3
# Tests: lease lifecycle, dynamic postgres role creation/revocation, reaper

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# TODO: test lease_create -> active state
# TODO: test lease_renew  -> extends TTL
# TODO: test lease_renew  -> fails after max_ttl
# TODO: test lease_revoke -> state becomes revoked
# TODO: test dynamic_postgres_read -> role exists in pg_roles, creds work
# TODO: test dynamic_revoke_credential -> role gone from pg_roles
# TODO: test DB-unreachable path -> state becomes revocation_pending
# TODO: test reaper eventually cleans up revocation_pending leases when DB returns

echo "Person 3 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
