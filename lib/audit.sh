#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"

audit_secret_file="$STATE_DIR/audit.secret"
audit_head_file="$STATE_DIR/audit.head"

audit_init() {
  if [[ ! -f "$audit_secret_file" ]]; then
    rand_hex 32 | atomic_write "$audit_secret_file"
    chmod 600 "$audit_secret_file"
  fi
  if [[ ! -f "$audit_head_file" ]]; then
    printf 'GENESIS' | atomic_write "$audit_head_file"
  fi
  touch "$AUDIT_LOG"
}

audit_hmac() {
  local payload="$1" secret
  secret="$(cat "$audit_secret_file")"
  printf '%s' "$payload" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$secret" -binary | base64 | tr -d '\n'
}

audit_append() {
  local token="$1" op="$2" path="$3" status="$4"
  audit_init
  local prev index entry payload hash
  prev="$(cat "$audit_head_file")"
  index="$(wc -l < "$AUDIT_LOG" | tr -d ' ')"
  entry="$(jq -nc \
    --argjson index "$index" \
    --arg ts "$(now_iso)" \
    --arg node_id "$NODE_ID" \
    --arg token "${token:-anonymous}" \
    --arg op "$op" \
    --arg path "$path" \
    --argjson status "$status" \
    --arg prev_hash "$prev" \
    '{index:$index,ts:$ts,node_id:$node_id,token:$token,op:$op,path:$path,status:$status,prev_hash:$prev_hash}')"
  payload="$(printf '%s' "$entry" | jq -cS .)"
  hash="$(audit_hmac "$payload")"
  printf '%s\n' "$(printf '%s' "$entry" | jq -c --arg hash "$hash" '. + {hash:$hash}')" >> "$AUDIT_LOG"
  printf '%s' "$hash" | atomic_write "$audit_head_file"
}

audit_query() {
  local token_filter="${1:-}"
  audit_init
  if [[ -z "$token_filter" ]]; then
    jq -s '[.[] | {ts,token,op,path,status}]' "$AUDIT_LOG"
  else
    jq -s --arg token "$token_filter" '[.[] | select(.token == $token) | {ts,token,op,path,status}]' "$AUDIT_LOG"
  fi
}
