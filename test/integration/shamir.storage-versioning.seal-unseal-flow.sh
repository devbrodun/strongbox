#!/usr/bin/env bash
# Tests for: Shamir, crypto envelope encryption, storage versioning, seal/unseal flow.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0
FAIL=0

_ok() { echo "  PASS: $1"; (( PASS++ )) || true; }
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

# ---------------------------------------------------------------------------
echo ""
echo "=== Shamir GF(2^8) tests ==="

SHAMIR="python3 $LIB_DIR/shamir.py"

# Basic 2-of-3 round-trip
SECRET="deadbeefcafebabe0102030405060708"
SHARES=$($SHAMIR split "$SECRET" 2 3)
S1=$(echo "$SHARES" | sed -n '1p')
S2=$(echo "$SHARES" | sed -n '2p')
S3=$(echo "$SHARES" | sed -n '3p')

R12=$($SHAMIR combine 2 "$S1" "$S2")
R13=$($SHAMIR combine 2 "$S1" "$S3")
R23=$($SHAMIR combine 2 "$S2" "$S3")

_assert_eq "2-of-3: shares 1+2 reconstruct" "$R12" "$SECRET"
_assert_eq "2-of-3: shares 1+3 reconstruct" "$R13" "$SECRET"
_assert_eq "2-of-3: shares 2+3 reconstruct" "$R23" "$SECRET"

# 3-of-5 round-trip
SECRET2="aabbccddeeff00112233445566778899"
SHARES5=$($SHAMIR split "$SECRET2" 3 5)
SA=$(echo "$SHARES5" | sed -n '1p')
SB=$(echo "$SHARES5" | sed -n '2p')
SC=$(echo "$SHARES5" | sed -n '3p')
SD=$(echo "$SHARES5" | sed -n '4p')
SE=$(echo "$SHARES5" | sed -n '5p')

R_ABC=$($SHAMIR combine 3 "$SA" "$SB" "$SC")
R_ADE=$($SHAMIR combine 3 "$SA" "$SD" "$SE")
R_BDE=$($SHAMIR combine 3 "$SB" "$SD" "$SE")

_assert_eq "3-of-5: shares A+B+C" "$R_ABC" "$SECRET2"
_assert_eq "3-of-5: shares A+D+E" "$R_ADE" "$SECRET2"
_assert_eq "3-of-5: shares B+D+E" "$R_BDE" "$SECRET2"

# Single share should NOT reconstruct correctly (will produce garbage, not error)
R_A_ONLY=$($SHAMIR combine 1 "$SA" 2>/dev/null || echo "error")
# It may or may not equal secret — just verify it doesn't when only 1 of 3 needed
if [[ "$R_A_ONLY" != "$SECRET2" ]]; then
    _ok "3-of-5: 1 share alone doesn't reconstruct"
else
    _fail "3-of-5: 1 share alone should NOT reconstruct (security property violated)"
fi

# Shares are distinct
_assert_ne "shares are distinct" "$SA" "$SB"

# 32-byte KEK (common case)
KEK=$(python3 -c "import secrets; print(secrets.token_hex(32))")
KSHARES=$($SHAMIR split "$KEK" 3 5)
KSA=$(echo "$KSHARES" | sed -n '1p')
KSB=$(echo "$KSHARES" | sed -n '2p')
KSC=$(echo "$KSHARES" | sed -n '3p')
RECK=$($SHAMIR combine 3 "$KSA" "$KSB" "$KSC")
_assert_eq "32-byte KEK round-trip" "$RECK" "$KEK"

# ---------------------------------------------------------------------------
echo ""
echo "=== Crypto envelope encryption tests ==="

export STRONGBOX_DATA_DIR="/tmp/strongbox-test-person1"
rm -rf "$STRONGBOX_DATA_DIR"
mkdir -p "$STRONGBOX_DATA_DIR"

source "$LIB_DIR/crypto.sh"
source "$LIB_DIR/storage.sh"

# Generate and load a test KEK
TEST_KEK=$(crypto_generate_kek)
crypto_load_kek "$TEST_KEK"

# Basic encrypt/decrypt
PLAINTEXT='{"password":"s3cr3t","user":"admin"}'
BLOB=$(crypto_encrypt_secret "$PLAINTEXT")
_assert_ne "ciphertext blob is not empty" "$BLOB" ""
_assert_ne "blob contains pipe separator" "${BLOB%%|*}" "$BLOB"

RECOVERED=$(crypto_decrypt_secret "$BLOB")
_assert_eq "decrypt recovers plaintext" "$RECOVERED" "$PLAINTEXT"

# Each encryption produces a different ciphertext (fresh DEK + nonce)
BLOB2=$(crypto_encrypt_secret "$PLAINTEXT")
_assert_ne "same plaintext -> different blob (fresh DEK)" "$BLOB" "$BLOB2"
RECOVERED2=$(crypto_decrypt_secret "$BLOB2")
_assert_eq "second blob also decrypts correctly" "$RECOVERED2" "$PLAINTEXT"

# Tampered blob fails to decrypt
TAMPERED="${BLOB:0:20}XXXX${BLOB:24}"
if ! RECOVERED3=$(crypto_decrypt_secret "$TAMPERED" 2>/dev/null); then
    _ok "tampered blob fails decryption (exit non-zero)"
elif [[ "$RECOVERED3" != "$PLAINTEXT" ]]; then
    _ok "tampered blob produces different output (GCM auth failed silently)"
else
    _fail "tampered blob should not decrypt to same plaintext"
fi

# Seal unloads KEK
crypto_unload_kek
if [[ -z "${STRONGBOX_KEK:-}" ]]; then
    _ok "unload_kek clears STRONGBOX_KEK"
else
    _fail "KEK still present after unload"
fi

# Operations while sealed should fail
if ! crypto_encrypt_secret "test" 2>/dev/null; then
    _ok "encrypt while sealed returns error"
else
    _fail "encrypt should fail while sealed"
fi

# Reload KEK for further tests
crypto_load_kek "$TEST_KEK"

# ---------------------------------------------------------------------------
echo ""
echo "=== Storage versioning tests ==="

# Write and read
V1=$(storage_put "secret/app/db" "$BLOB")
_assert_eq "first write returns version 1" "$V1" "1"

FETCHED=$(storage_get "secret/app/db")
_assert_eq "read latest returns v1 blob" "$FETCHED" "$BLOB"

# Second write creates new version
V2=$(storage_put "secret/app/db" "$BLOB2")
_assert_eq "second write returns version 2" "$V2" "2"

LATEST=$(storage_get "secret/app/db")
_assert_eq "read latest returns v2 blob" "$LATEST" "$BLOB2"

V1_FETCH=$(storage_get "secret/app/db" 1)
_assert_eq "read v1 by version returns original blob" "$V1_FETCH" "$BLOB"

VER=$(storage_latest_version "secret/app/db")
_assert_eq "latest_version returns 2" "$VER" "2"

# Different paths are independent
V_OTHER=$(storage_put "secret/other/x" "$BLOB")
_assert_eq "other path starts at version 1" "$V_OTHER" "1"

VER_ORIG=$(storage_latest_version "secret/app/db")
_assert_eq "original path unaffected by other path" "$VER_ORIG" "2"

# List
LISTED=$(storage_list "secret/app/")
if echo "$LISTED" | grep -q "secret/app/db"; then
    _ok "storage_list finds secret/app/db"
else
    _fail "storage_list missing secret/app/db"
fi

# Delete
storage_delete "secret/app/db"
if ! storage_get "secret/app/db" 2>/dev/null; then
    _ok "deleted path returns error on get"
else
    _fail "deleted path should not be readable"
fi

if ! storage_exists "secret/app/db"; then
    _ok "storage_exists returns false after delete"
else
    _fail "storage_exists should return false after delete"
fi

# Invalid version
if ! storage_get "secret/other/x" 999 2>/dev/null; then
    _ok "out-of-range version returns error"
else
    _fail "out-of-range version should fail"
fi

# Path traversal rejected
if ! storage_put "secret/../../etc/passwd" "bad" 2>/dev/null; then
    _ok "path traversal rejected"
else
    _fail "path traversal should be rejected"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Seal/unseal memory hygiene test ==="

# Simulate unseal: split KEK, collect shares, reconstruct, zero
TEST_KEK2=$(crypto_generate_kek)
SPLIT_OUT=$(python3 "$LIB_DIR/shamir.py" split "$TEST_KEK2" 2 3)

crypto_unload_kek
SHR1=$(echo "$SPLIT_OUT" | sed -n '1p')
SHR2=$(echo "$SPLIT_OUT" | sed -n '2p')

RECON=$(python3 "$LIB_DIR/shamir.py" combine 2 "$SHR1" "$SHR2")
_assert_eq "reconstructed key matches original" "$RECON" "$TEST_KEK2"

crypto_load_kek "$RECON"

# Zero local copies (as the unseal handler does)
RECON="$(printf '%0.s0' $(seq 1 ${#RECON}))"
SHR1="$(printf '%0.s0' $(seq 1 ${#SHR1}))"
SHR2="$(printf '%0.s0' $(seq 1 ${#SHR2}))"
unset RECON SHR1 SHR2

# KEK should be loaded and operational
BLOB3=$(crypto_encrypt_secret "post-unseal secret")
R3=$(crypto_decrypt_secret "$BLOB3")
_assert_eq "post-unseal encrypt/decrypt works" "$R3" "post-unseal secret"

# Seal again
crypto_unload_kek
if [[ -z "${STRONGBOX_KEK:-}" ]]; then
    _ok "KEK zeroed after seal"
else
    _fail "KEK not zeroed after seal"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0