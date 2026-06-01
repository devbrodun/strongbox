#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"

crypto_cmd_fifo="$RUNTIME_DIR/crypto.cmd"
crypto_legacy_kek_file="$RUNTIME_DIR/kek.hex"

crypto_is_unsealed() {
  [[ "$(crypto_call STATUS 2>/dev/null || true)" == "unsealed" ]]
}

crypto_set_kek() {
  local kek="$1"
  rm -f "$crypto_legacy_kek_file"
  crypto_call SET "$kek" >/dev/null
}

crypto_purge_kek() {
  crypto_call PURGE >/dev/null 2>&1 || true
  rm -f "$crypto_legacy_kek_file"
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

crypto_reply() {
  local resp="$1" status="$2" body="${3:-}"
  [[ -p "$resp" ]] || return 0
  if [[ -n "$body" ]]; then
    printf '%s %s\n' "$status" "$body" > "$resp"
  else
    printf '%s\n' "$status" > "$resp"
  fi
}

crypto_daemon_loop() {
  local kek="" op resp arg result
  rm -f "$crypto_cmd_fifo" "$crypto_legacy_kek_file"
  mkfifo -m 600 "$crypto_cmd_fifo"
  while true; do
    IFS=' ' read -r op resp arg < "$crypto_cmd_fifo" || continue
    case "$op" in
      STATUS)
        if [[ -n "$kek" ]]; then
          crypto_reply "$resp" OK unsealed
        else
          crypto_reply "$resp" OK sealed
        fi
        ;;
      SET)
        if [[ "$arg" =~ ^[0-9a-fA-F]{64}$ ]]; then
          kek="$arg"
          crypto_reply "$resp" OK
        else
          crypto_reply "$resp" ERR invalid_kek
        fi
        ;;
      PURGE)
        kek="$(printf '%064d' 0)"
        kek=""
        crypto_reply "$resp" OK
        ;;
      WRAP_DEK)
        if [[ -n "$kek" ]]; then
          result="$(printf '%s' "$arg" | cms_encrypt_b64 "$kek")"
          crypto_reply "$resp" OK "$result"
        else
          crypto_reply "$resp" ERR sealed
        fi
        ;;
      UNWRAP_DEK)
        if [[ -n "$kek" ]]; then
          result="$(cms_decrypt_b64 "$kek" "$arg")"
          crypto_reply "$resp" OK "$result"
        else
          crypto_reply "$resp" ERR sealed
        fi
        ;;
      *)
        crypto_reply "$resp" ERR unknown_command
        ;;
    esac
  done
}

crypto_call() {
  local op="$1" arg="${2:-}" resp out
  [[ -p "$crypto_cmd_fifo" ]] || return 1
  resp="$(mktemp -u "$RUNTIME_DIR/crypto.resp.XXXXXX")"
  mkfifo -m 600 "$resp"
  printf '%s %s %s\n' "$op" "$resp" "$arg" > "$crypto_cmd_fifo" || {
    rm -f "$resp"
    return 1
  }
  IFS= read -r out < "$resp" || true
  rm -f "$resp"
  case "$out" in
    OK) return 0 ;;
    OK\ *) printf '%s' "${out#OK }" ;;
    *) return 1 ;;
  esac
}

crypto_wrap_dek() {
  local dek="$1"
  crypto_call WRAP_DEK "$dek"
}

crypto_unwrap_dek() {
  local wrapped_dek="$1"
  crypto_call UNWRAP_DEK "$wrapped_dek"
}

crypto_encrypt_secret() {
  local plaintext_json="$1" dek ciphertext wrapped_dek
  dek="$(rand_hex 32)"
  ciphertext="$(printf '%s' "$plaintext_json" | cms_encrypt_b64 "$dek")"
  wrapped_dek="$(crypto_wrap_dek "$dek")"
  dek="$(printf '%064d' 0)"
  jq -nc --arg alg "AES-256-GCM-CMS" --arg ciphertext "$ciphertext" --arg wrapped_dek "$wrapped_dek" \
    '{alg:$alg,ciphertext:$ciphertext,wrapped_dek:$wrapped_dek}'
}

crypto_decrypt_secret() {
  local envelope="$1" wrapped_dek ciphertext dek
  wrapped_dek="$(printf '%s' "$envelope" | jq -r '.wrapped_dek')"
  ciphertext="$(printf '%s' "$envelope" | jq -r '.ciphertext')"
  dek="$(crypto_unwrap_dek "$wrapped_dek")"
  cms_decrypt_b64 "$dek" "$ciphertext"
  dek="$(printf '%064d' 0)"
}
