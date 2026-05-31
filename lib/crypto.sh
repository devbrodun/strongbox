#!/usr/bin/env bash
# lib/crypto.sh — Envelope encryption for StrongBox
#
# Design:
#   - Every secret value is encrypted with a random 256-bit Data Encryption Key (DEK).
#   - The DEK is wrapped (encrypted) by the Key Encryption Key (KEK), the master key.
#   - The KEK lives only in memory (exported as STRONGBOX_KEK) after unseal.
#   - The KEK is NEVER written to disk or logged.
#
# Nonce strategy:
#   - 96-bit (12-byte) random nonce per encryption, generated via /dev/urandom.
#   - Nonces are prepended to ciphertext: [nonce(12)] [tag(16)] [ciphertext]
#   - Random nonces at 96 bits give negligible collision probability for our
#     secret counts; counter nonces would require durable state we intentionally
#     avoid so that the storage backend stays simple.
#
# Storage format (base64-encoded blob stored alongside each secret):
#   wrapped_dek_b64|encrypted_value_b64
#   where:
#     wrapped_dek_b64   = base64( nonce(12) || tag(16) || enc_dek(32) )
#     encrypted_value_b64 = base64( nonce(12) || tag(16) || ciphertext )

set -euo pipefail

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_crypto_require_kek() {
    if [[ -z "${STRONGBOX_KEK:-}" ]]; then
        echo "ERROR: KEK not loaded (vault is sealed)" >&2
        return 1
    fi
}

# Generate N random bytes, returned as lowercase hex.
_crypto_random_hex() {
    local n="${1:?byte count required}"
    dd if=/dev/urandom bs=1 count="$n" 2>/dev/null | xxd -p | tr -d '\n'
}

# AES-256-GCM encrypt.
# Args: key_hex  nonce_hex  plaintext_hex
# Stdout: ciphertext_hex
# Also sets _CRYPTO_TAG (16-byte tag hex) as a side effect via temp file.
_crypto_aes_gcm_encrypt() {
    local key_hex="${1:?}" nonce_hex="${2:?}" plaintext_hex="${3:?}"
    local helper_path
    helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto_helper.py"

    local out
    out=$(python3 "$helper_path" encrypt "$key_hex" "$nonce_hex" "$plaintext_hex")

    local tag_hex="${out: -32}"
    local ct_hex="${out:0:${#out}-32}"
    printf '%s|%s' "$tag_hex" "$ct_hex"
}

# AES-256-GCM decrypt.
# Args: key_hex  nonce_hex  tag_hex  ciphertext_hex
# Stdout: plaintext_hex
_crypto_aes_gcm_decrypt() {
    local key_hex="${1:?}" nonce_hex="${2:?}" tag_hex="${3:?}" ct_hex="${4:?}"
    local helper_path
    helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto_helper.py"

    python3 "$helper_path" decrypt "$key_hex" "$nonce_hex" "$tag_hex" "$ct_hex"
}

# Encode raw hex as base64.
_crypto_hex_to_b64() { printf '%s' "${1:?}" | xxd -r -p | base64 -w 0; }

# Decode base64 to hex.
_crypto_b64_to_hex() { printf '%s' "${1:?}" | base64 -d | xxd -p | tr -d '\n'; }

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# crypto_generate_kek
# Generate a new 256-bit KEK (returned as hex). Used only during init.
# The caller is responsible for splitting it via Shamir and zeroing the variable.
crypto_generate_kek() {
    _crypto_random_hex 32
}

# crypto_load_kek  <kek_hex>
# Load the reconstructed KEK into the process environment.
# Called by the unseal sequence after Shamir reconstruction.
# The kek_hex argument variable should be zeroed by the caller immediately after.
crypto_load_kek() {
    local kek_hex="${1:?}"
    export STRONGBOX_KEK="$kek_hex"
    export STRONGBOX_AUDIT_SECRET
    STRONGBOX_AUDIT_SECRET=$(echo -n "audit_secret_salt" | openssl dgst -sha256 -hmac "$kek_hex" | awk '{print $NF}')
}

# crypto_unload_kek
# Zero and unset the KEK from memory. Called on seal.
crypto_unload_kek() {
    if [[ -n "${STRONGBOX_KEK:-}" ]]; then
        # Overwrite the variable before unsetting (best-effort in bash)
        STRONGBOX_KEK="$(printf '%0.s0' $(seq 1 ${#STRONGBOX_KEK}))"
        unset STRONGBOX_KEK
    fi
    if [[ -n "${STRONGBOX_AUDIT_SECRET:-}" ]]; then
        STRONGBOX_AUDIT_SECRET="$(printf '%0.s0' $(seq 1 ${#STRONGBOX_AUDIT_SECRET}))"
        unset STRONGBOX_AUDIT_SECRET
    fi
}

# crypto_encrypt_secret  <plaintext>
# Encrypt a secret value with a fresh random DEK, wrap the DEK with the KEK.
# Stdout: wrapped_dek_b64|encrypted_value_b64
crypto_encrypt_secret() {
    _crypto_require_kek || return 1
    local plaintext="${1:?plaintext required}"
    local kek_hex="$STRONGBOX_KEK"

    # 1. Generate fresh DEK (32 bytes)
    local dek_hex
    dek_hex=$(_crypto_random_hex 32)

    # 2. Encrypt the plaintext with the DEK
    local val_nonce_hex val_ct_hex val_tag val_enc_res
    val_nonce_hex=$(_crypto_random_hex 12)
    local plaintext_hex
    plaintext_hex=$(printf '%s' "$plaintext" | xxd -p | tr -d '\n')
    val_enc_res=$(_crypto_aes_gcm_encrypt "$dek_hex" "$val_nonce_hex" "$plaintext_hex")
    val_tag="${val_enc_res%%|*}"
    val_ct_hex="${val_enc_res##*|}"

    # 3. Wrap the DEK with the KEK
    local dek_nonce_hex dek_ct_hex dek_tag dek_enc_res
    dek_nonce_hex=$(_crypto_random_hex 12)
    dek_enc_res=$(_crypto_aes_gcm_encrypt "$kek_hex" "$dek_nonce_hex" "$dek_hex")
    dek_tag="${dek_enc_res%%|*}"
    dek_ct_hex="${dek_enc_res##*|}"

    # 4. Pack: nonce(24 hex) || tag(32 hex) || ct_hex → base64
    local wrapped_dek_b64 encrypted_val_b64
    wrapped_dek_b64=$(_crypto_hex_to_b64 "${dek_nonce_hex}${dek_tag}${dek_ct_hex}")
    encrypted_val_b64=$(_crypto_hex_to_b64 "${val_nonce_hex}${val_tag}${val_ct_hex}")

    # Zero DEK from local scope (best-effort)
    dek_hex="$(printf '%0.s0' $(seq 1 ${#dek_hex}))"
    unset dek_hex

    printf '%s|%s' "$wrapped_dek_b64" "$encrypted_val_b64"
}

# crypto_decrypt_secret  <wrapped_dek_b64|encrypted_value_b64>
# Decrypt a secret previously encrypted with crypto_encrypt_secret.
# Stdout: plaintext
crypto_decrypt_secret() {
    _crypto_require_kek || return 1
    local blob="${1:?blob required}"
    local kek_hex="$STRONGBOX_KEK"

    local wrapped_dek_b64 encrypted_val_b64
    wrapped_dek_b64="${blob%%|*}"
    encrypted_val_b64="${blob##*|}"

    # 1. Decode wrapped DEK blob
    local dek_blob_hex
    dek_blob_hex=$(_crypto_b64_to_hex "$wrapped_dek_b64")
    local dek_nonce_hex="${dek_blob_hex:0:24}"
    local dek_tag_hex="${dek_blob_hex:24:32}"
    local dek_ct_hex="${dek_blob_hex:56}"

    # 2. Unwrap DEK
    local dek_hex
    dek_hex=$(_crypto_aes_gcm_decrypt "$kek_hex" "$dek_nonce_hex" "$dek_tag_hex" "$dek_ct_hex")

    # 3. Decode encrypted value blob
    local val_blob_hex
    val_blob_hex=$(_crypto_b64_to_hex "$encrypted_val_b64")
    local val_nonce_hex="${val_blob_hex:0:24}"
    local val_tag_hex="${val_blob_hex:24:32}"
    local val_ct_hex="${val_blob_hex:56}"

    # 4. Decrypt value
    local plaintext_hex
    plaintext_hex=$(_crypto_aes_gcm_decrypt "$dek_hex" "$val_nonce_hex" "$val_tag_hex" "$val_ct_hex")

    # Zero DEK
    dek_hex="$(printf '%0.s0' $(seq 1 ${#dek_hex}))"
    unset dek_hex

    printf '%s' "$plaintext_hex" | xxd -r -p
}

# crypto_wrap_kek  <kek_hex>  <passphrase>
# Derive a wrapping key from passphrase via Argon2id, wrap the KEK.
# Used during init to produce the per-share KEK backup.
# Stdout: argon2_params_b64|wrapped_kek_b64
# (This is only for the optional passphrase path; normally the KEK is
#  reconstructed via Shamir shares.)
crypto_wrap_kek_with_passphrase() {
    local kek_hex="${1:?}" passphrase="${2:?}"

    local salt_hex
    salt_hex=$(_crypto_random_hex 16)

    # Argon2id via CLI: memory=65536 KB, iterations=3, parallelism=1
    local derived_hex
    derived_hex=$(printf '%s' "$passphrase" \
        | argon2 "$(printf '%s' "$salt_hex" | xxd -r -p)" \
            -id -t 3 -m 16 -p 1 -l 32 -r \
        | tr -d '\n')

    local nonce_hex
    nonce_hex=$(_crypto_random_hex 12)
    
    local enc_res tag_hex ct_hex
    enc_res=$(_crypto_aes_gcm_encrypt "$derived_hex" "$nonce_hex" "$kek_hex")
    tag_hex="${enc_res%%|*}"
    ct_hex="${enc_res##*|}"

    local params_b64
    params_b64=$(printf 'argon2id$t=3,m=65536,p=1$%s' "$salt_hex" | base64 -w 0)
    local wrapped_b64
    wrapped_b64=$(_crypto_hex_to_b64 "${nonce_hex}${tag_hex}${ct_hex}")

    printf '%s|%s' "$params_b64" "$wrapped_b64"
}