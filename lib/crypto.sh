#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"

kek_file="$RUNTIME_DIR/kek.hex"

crypto_is_unsealed() {
  [[ -s "$kek_file" ]]
}

crypto_get_kek() {
  crypto_is_unsealed || return 1
  cat "$kek_file"
}

crypto_set_kek() {
  local kek="$1"
  umask 077
  printf '%s' "$kek" > "$kek_file"
}

crypto_purge_kek() {
  if [[ -f "$kek_file" ]]; then
    : > "$kek_file"
    rm -f "$kek_file"
  fi
}

cms_encrypt_b64() {
  local key_hex="$1"
  local in tmp
  in="$(mktemp "$RUNTIME_DIR/plain.XXXXXX")"
  tmp="$(mktemp "$RUNTIME_DIR/cms.XXXXXX")"
  cat > "$in"
  openssl cms -encrypt -aes-256-gcm -secretkey "$key_hex" -secretkeyid 01 -in "$in" -out "$tmp" -outform DER -binary >/dev/null 2>&1
  base64 < "$tmp" | tr -d '\n'
  : > "$in"; : > "$tmp"; rm -f "$in" "$tmp"
}

cms_decrypt_b64() {
  local key_hex="$1" b64="$2"
  local in out
  in="$(mktemp "$RUNTIME_DIR/cms.XXXXXX")"
  out="$(mktemp "$RUNTIME_DIR/plain.XXXXXX")"
  printf '%s' "$b64" | base64 -d > "$in"
  openssl cms -decrypt -inform DER -in "$in" -secretkey "$key_hex" -secretkeyid 01 -out "$out" -binary >/dev/null 2>&1
  cat "$out"
  : > "$in"; : > "$out"; rm -f "$in" "$out"
}

crypto_encrypt_secret() {
  local plaintext_json="$1" kek dek ciphertext wrapped_dek
  kek="$(crypto_get_kek)"
  dek="$(rand_hex 32)"
  ciphertext="$(printf '%s' "$plaintext_json" | cms_encrypt_b64 "$dek")"
  wrapped_dek="$(printf '%s' "$dek" | cms_encrypt_b64 "$kek")"
  dek="$(printf '%064d' 0)"
  jq -nc --arg alg "AES-256-GCM-CMS" --arg ciphertext "$ciphertext" --arg wrapped_dek "$wrapped_dek" \
    '{alg:$alg,ciphertext:$ciphertext,wrapped_dek:$wrapped_dek}'
}

crypto_decrypt_secret() {
  local envelope="$1" kek wrapped_dek ciphertext dek
  kek="$(crypto_get_kek)"
  wrapped_dek="$(printf '%s' "$envelope" | jq -r '.wrapped_dek')"
  ciphertext="$(printf '%s' "$envelope" | jq -r '.ciphertext')"
  dek="$(cms_decrypt_b64 "$kek" "$wrapped_dek")"
  cms_decrypt_b64 "$dek" "$ciphertext"
  dek="$(printf '%064d' 0)"
}
