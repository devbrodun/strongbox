#!/usr/bin/env bash
# Tests: token creation, policy enforcement, revocation, audit chain, verify tool

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../../bin" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1"; (( FAIL++ )) || true; }

_assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then _ok "$label"
    else _fail "$label (got='$got' want='$want')"; fi
}

_assert_exit0() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then _ok "$label"
    else _fail "$label (expected exit 0)"; fi
}

_assert_exit1() {
    local label="$1"; shift
    if ! "$@" >/dev/null 2>&1; then _ok "$label"
    else _fail "$label (expected non-zero exit)"; fi
}

echo ""
echo "=== Token Auth and Policy Enforcement tests ==="

# Setup test environments
export STRONGBOX_DATA_DIR="/tmp/strongbox-test-person2"
rm -rf "$STRONGBOX_DATA_DIR"
mkdir -p "$STRONGBOX_DATA_DIR"

# Source necessary modules
source "$LIB_DIR/crypto.sh"
source "$LIB_DIR/auth.sh"
source "$LIB_DIR/audit.sh"

export STRONGBOX_AUDIT_LOG="/tmp/strongbox-test-audit.log"
export STRONGBOX_AUDIT_SECRET="testsecret123"
rm -f "$STRONGBOX_AUDIT_LOG"

# 1. Root token creation & validation
ROOT_TOKEN=$(auth_create_root_token)
_assert_eq "Root token generated (32 bytes)" "${#ROOT_TOKEN}" "64" # 32-byte hex is 64 chars

if auth_validate_token "$ROOT_TOKEN" "secret/any/path" "write"; then
    _ok "Root token has write access to any path"
else
    _fail "Root token should have full write access"
fi

if auth_validate_token "$ROOT_TOKEN" "secret/any/path" "read"; then
    _ok "Root token has read access to any path"
else
    _fail "Root token should have full read access"
fi

# 2. Scoped policies and token validation
# Let's define a policy "app-read" allowing read on "secret/app/*"
# and "app-write" allowing write on "secret/app/*"
if declare -p _AUTH_POLICIES 2>/dev/null | grep -q 'declare -A'; then
    _AUTH_POLICIES["app-read"]='{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}'
    _AUTH_POLICIES["app-write"]='{"rules":[{"path":"secret/app/*","capabilities":["write"]}]}'
else
    mkdir -p "${STRONGBOX_DATA_DIR}/policies"
    echo '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}' > "${STRONGBOX_DATA_DIR}/policies/app-read"
    echo '{"rules":[{"path":"secret/app/*","capabilities":["write"]}]}' > "${STRONGBOX_DATA_DIR}/policies/app-write"
fi

READ_TOKEN=$(auth_create_token "testuser" "app-read")
WRITE_TOKEN=$(auth_create_token "testuser" "app-write")

# Read token validations
if auth_validate_token "$READ_TOKEN" "secret/app/db" "read"; then
    _ok "Read token allows read on matched path secret/app/db"
else
    _fail "Read token should allow read on matched path"
fi

if ! auth_validate_token "$READ_TOKEN" "secret/app/db" "write"; then
    _ok "Read token rejects write on matched path secret/app/db"
else
    _fail "Read token should reject write on matched path"
fi

if ! auth_validate_token "$READ_TOKEN" "secret/prod/db" "read"; then
    _ok "Read token rejects read on unmatched path secret/prod/db"
else
    _fail "Read token should reject read on unmatched path"
fi

# Write token validations
if auth_validate_token "$WRITE_TOKEN" "secret/app/db" "write"; then
    _ok "Write token allows write on matched path secret/app/db"
else
    _fail "Write token should allow write on matched path"
fi

if ! auth_validate_token "$WRITE_TOKEN" "secret/app/db" "read"; then
    _ok "Write token rejects read on matched path secret/app/db"
else
    _fail "Write token should reject read on matched path"
fi

# 3. Synchronous Revocation
if declare -p _AUTH_REVOKED 2>/dev/null | grep -q 'declare -A'; then
    _AUTH_REVOKED["$READ_TOKEN"]="1"
else
    mkdir -p "${STRONGBOX_DATA_DIR}/auth/revoked"
    echo "1" > "${STRONGBOX_DATA_DIR}/auth/revoked/${READ_TOKEN}"
fi
if ! auth_validate_token "$READ_TOKEN" "secret/app/db" "read"; then
    _ok "Revoked token is immediately rejected"
else
    _fail "Revoked token should fail validation"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Audit Logging and Verification tests ==="

# Trigger some audits
audit_append "secrets" "$WRITE_TOKEN" "write" "secret/app/db" "success"
audit_append "secrets" "$WRITE_TOKEN" "read" "secret/app/db" "success"
audit_append "auth" "$ROOT_TOKEN" "login" "auth/login" "success"

if [[ -f "$STRONGBOX_AUDIT_LOG" ]]; then
    _ok "Audit log file was successfully created"
else
    _fail "Audit log file should exist"
fi

LINE_COUNT=$(wc -l < "$STRONGBOX_AUDIT_LOG" | xargs)
_assert_eq "Audit log contains expected number of entries (3)" "$LINE_COUNT" "3"

# Run strongbox-verify on the clean log
export STRONGBOX_AUDIT_SECRET
_assert_exit0 "Verify tool reports OK on clean audit log" bash "$BIN_DIR/strongbox-verify" "$STRONGBOX_AUDIT_LOG"

# Tamper the audit log by replacing the first 's' in success to 'x' on the last line
cp "$STRONGBOX_AUDIT_LOG" "${STRONGBOX_AUDIT_LOG}.tampered"
sed -i '3s/"success"/"succesx"/' "${STRONGBOX_AUDIT_LOG}.tampered" 2>/dev/null || sed -i "" '3s/"success"/"succesx"/' "${STRONGBOX_AUDIT_LOG}.tampered"

# Verification on tampered log should exit non-zero
_assert_exit1 "Verify tool exits non-zero on tampered audit log" bash "$BIN_DIR/strongbox-verify" "${STRONGBOX_AUDIT_LOG}.tampered"

# Clean up
rm -f "$STRONGBOX_AUDIT_LOG" "${STRONGBOX_AUDIT_LOG}.tampered"

echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
