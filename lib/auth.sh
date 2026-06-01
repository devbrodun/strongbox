#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"
source "$SB_ROOT/lib/storage.sh"

token_hash() {
  printf '%s' "$1" | openssl dgst -sha256 -binary | base64 | tr -d '\n'
}

token_id_for() {
  printf '%s' "$1" | openssl dgst -sha256 -hex | awk '{print substr($2,1,24)}'
}

auth_create_token() {
  local policies_json="$1" ttl="${2:-86400}" token token_id hash expires record
  token="$(rand_b64url 48)"
  token_id="$(token_id_for "$token")"
  hash="$(token_hash "$token")"
  expires="$(( $(now_epoch) + ttl ))"
  record="$(jq -nc --arg id "$token_id" --arg hash "$hash" --argjson policies "$policies_json" \
    --argjson created "$(now_epoch)" --argjson expires "$expires" \
    '{id:$id,hash:$hash,policies:$policies,created_at:$created,expires_at:$expires,revoked:false}')"
  storage_put auth "token/$token_id" "$record"
  jq -nc --arg token "$token" --arg token_id "$token_id" --argjson policies "$policies_json" \
    '{token:$token,token_id:$token_id,policies:$policies}'
}

auth_create_root_policy() {
  local rules
  rules='{"rules":[{"path":"*","capabilities":["read","write","delete","sudo"]}]}'
  storage_put policies root "$rules"
}

auth_lookup_token() {
  local token="$1" token_id hash record
  token_id="$(token_id_for "$token")"
  hash="$(token_hash "$token")"
  record="$(storage_get auth "token/$token_id")" || return 1
  [[ "$(printf '%s' "$record" | jq -r '.hash')" == "$hash" ]] || return 1
  [[ "$(printf '%s' "$record" | jq -r '.revoked')" == "false" ]] || return 1
  [[ "$(printf '%s' "$record" | jq -r '.expires_at')" -gt "$(now_epoch)" ]] || return 1
  printf '%s' "$record"
}

auth_revoke_token_value() {
  local token="$1" token_id record
  token_id="$(token_id_for "$token")"
  record="$(storage_get auth "token/$token_id")" || return 1
  storage_put auth "token/$token_id" "$(printf '%s' "$record" | jq '.revoked=true | .revoked_at=(now|floor)')"
}

auth_revoke_token_id() {
  local token_id="$1" record
  record="$(storage_get auth "token/$token_id")" || return 1
  storage_put auth "token/$token_id" "$(printf '%s' "$record" | jq '.revoked=true | .revoked_at=(now|floor)')"
}

auth_policy_allows() {
  local token_record="$1" capability="$2" path="$3"
  local policy rules allowed
  allowed="false"
  while read -r policy; do
    rules="$(storage_get policies "$policy" 2>/dev/null || printf '{"rules":[]}')"
    if printf '%s' "$rules" | jq -e --arg cap "$capability" --arg path "$path" '
      .rules[]? as $r |
      ($r.capabilities | index($cap) or index("sudo")) and
      (($r.path == "*") or
       ($r.path | endswith("*") and ($path | startswith($r.path[0:-1]))) or
       ($r.path == $path))
    ' >/dev/null; then
      allowed="true"
      break
    fi
  done < <(printf '%s' "$token_record" | jq -r '.policies[]')
  [[ "$allowed" == "true" ]]
}

auth_hash_password() {
  local password="$1" salt
  salt="$(openssl rand -base64 16)"
  printf '%s' "$password" | argon2 "$salt" -id -e
}

auth_verify_password() {
  local password="$1" encoded="$2"
  printf '%s' "$password" | argon2 "$(printf '%s' "$encoded" | awk -F '$' '{print $5}')" -id -e | grep -qxF "$encoded"
}

auth_login() {
  local username="$1" password="$2" user encoded policies
  user="$(storage_get users "$username")" || return 1
  encoded="$(printf '%s' "$user" | jq -r '.password_hash')"
  auth_verify_password "$password" "$encoded" || return 1
  policies="$(printf '%s' "$user" | jq -c '.policies')"
  auth_create_token "$policies" 3600
}
