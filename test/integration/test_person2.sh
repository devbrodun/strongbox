#!/usr/bin/env bash
# test/integration/test_person2.sh
# OWNER: Person 2
# Tests: token creation, policy enforcement, revocation, audit chain, verify tool

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# TODO: test auth_create_token + auth_validate_token (allowed path/cap)
# TODO: test policy enforcement: read-only token -> 200 on read, 403 on write
# TODO: test revocation: revoke token -> next call fails immediately (no grace)
# TODO: test audit_append -> audit log grows
# TODO: test strongbox-verify passes on clean log
# TODO: test strongbox-verify exits non-zero after single-byte tamper, names entry

echo "Person 2 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
