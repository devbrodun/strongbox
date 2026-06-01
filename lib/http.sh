#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"
source "$SB_ROOT/lib/storage.sh"
source "$SB_ROOT/lib/audit.sh"
source "$SB_ROOT/lib/crypto.sh"
source "$SB_ROOT/lib/auth.sh"
source "$SB_ROOT/lib/consensus.sh"
source "$SB_ROOT/lib/dynamic.sh"

REQ_METHOD=""
REQ_TARGET=""
REQ_PATH=""
REQ_QUERY=""
REQ_BODY=""
REQ_AUTH=""
REQ_TOKEN_RECORD=""
REQ_TOKEN_ID="anonymous"

http_read_request() {
  local line header key value len
  IFS=' ' read -r REQ_METHOD REQ_TARGET _ || return 1
  REQ_TARGET="${REQ_TARGET%$'\r'}"
  REQ_PATH="${REQ_TARGET%%\?*}"
  REQ_QUERY=""
  [[ "$REQ_TARGET" == *"?"* ]] && REQ_QUERY="${REQ_TARGET#*\?}"
  len=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && break
    key="${line%%:*}"
    value="${line#*: }"
    case "${key,,}" in
      content-length) len="$value" ;;
      authorization) REQ_AUTH="$value" ;;
    esac
  done
  REQ_BODY=""
  if [[ "$len" =~ ^[0-9]+$ && "$len" -gt 0 ]]; then
    IFS= read -r -N "$len" REQ_BODY || true
  fi
}

query_param() {
  local name="$1" part
  tr '&' '\n' <<< "$REQ_QUERY" | while IFS= read -r part; do
    [[ "${part%%=*}" == "$name" ]] && url_decode "${part#*=}" && break
  done
  return 0
}

sealed() {
  ! crypto_is_unsealed
}

require_unsealed() {
  if sealed; then
    error_response 503 "strongbox is sealed"
    return 1
  fi
}

require_auth() {
  local token
  [[ "$REQ_AUTH" == Bearer\ * ]] || { error_response 401 "missing bearer token"; return 1; }
  token="${REQ_AUTH#Bearer }"
  REQ_TOKEN_RECORD="$(auth_lookup_token "$token")" || { audit_append anonymous auth.denied "$REQ_PATH" 401; error_response 401 "invalid token"; return 1; }
  REQ_TOKEN_ID="$(printf '%s' "$REQ_TOKEN_RECORD" | jq -r '.id')"
}

require_capability() {
  local cap="$1" path="$2"
  auth_policy_allows "$REQ_TOKEN_RECORD" "$cap" "$path" || {
    audit_append "$REQ_TOKEN_ID" auth.forbidden "$path" 403
    error_response 403 "policy denied"
    return 1
  }
}

require_leader_for_write() {
  if ! consensus_is_leader; then
    json_response 409 "$(consensus_leader_hint_json | jq '. + {error:"not leader"}')"
    return 1
  fi
}

replicate_put() {
  local ns="$1" key="$2" value="$3" payload
  payload="$(jq -nc --arg op storage_put --arg ns "$ns" --arg key "$key" --argjson value "$value" \
    '{op:$op,ns:$ns,key:$key,value:$value}')"
  consensus_replicate "$payload"
}

handle_internal_replicate() {
  local op ns key value
  op="$(printf '%s' "$REQ_BODY" | jq -r '.op')"
  case "$op" in
    storage_put)
      ns="$(printf '%s' "$REQ_BODY" | jq -r '.ns')"
      key="$(printf '%s' "$REQ_BODY" | jq -r '.key')"
      value="$(printf '%s' "$REQ_BODY" | jq -c '.value')"
      storage_put "$ns" "$key" "$value"
      json_response 200 '{"ok":true}'
      ;;
    storage_delete)
      ns="$(printf '%s' "$REQ_BODY" | jq -r '.ns')"
      key="$(printf '%s' "$REQ_BODY" | jq -r '.key')"
      storage_delete "$ns" "$key"
      json_response 200 '{"ok":true}'
      ;;
    leader)
      consensus_set_leader "$(printf '%s' "$REQ_BODY" | jq -r '.leader')"
      json_response 200 '{"ok":true}'
      ;;
    *)
      error_response 400 "unknown replication op"
      ;;
  esac
}

handle_internal_vote() {
  local resp
  resp="$(consensus_handle_vote_request "$REQ_BODY")"
  json_response 200 "$resp"
}

handle_internal_heartbeat() {
  local resp
  resp="$(consensus_handle_heartbeat "$REQ_BODY")"
  json_response 200 "$resp"
}

sys_init() {
  storage_exists sys init && { error_response 409 "already initialized"; return; }
  local k n master kek wrapped shares root root_token root_token_id token_record meta
  k="$(config_get seal.threshold 3)"
  n="$(config_get seal.shares 5)"
  master="$(rand_hex 32)"
  kek="$(rand_hex 32)"
  wrapped="$(printf '%s' "$kek" | cms_encrypt_b64 "$master")"
  meta="$(jq -nc --argjson k "$k" --argjson n "$n" --arg wrapped_kek "$wrapped" '{initialized:true,threshold:$k,shares:$n,wrapped_kek:$wrapped_kek}')"
  storage_put sys init "$meta"
  auth_create_root_policy
  root="$(auth_create_token '["root"]' 315360000)"
  root_token="$(printf '%s' "$root" | jq -r '.token')"
  root_token_id="$(printf '%s' "$root" | jq -r '.token_id')"
  token_record="$(storage_get auth "token/$root_token_id")"
  replicate_put sys init "$meta" || true
  replicate_put policies root "$(storage_get policies root)" || true
  replicate_put auth "token/$root_token_id" "$token_record" || true
  shares="$(python3 "$SB_ROOT/lib/shamir.py" split "$k" "$n" "$master" | jq -R . | jq -s .)"
  master="$(printf '%064d' 0)"
  kek="$(printf '%064d' 0)"
  audit_append anonymous sys.init /v1/sys/init 201
  json_response 201 "$(jq -nc --argjson shares "$shares" --arg root_token "$root_token" '{shares:$shares,root_token:$root_token}')"
}

sys_unseal() {
  storage_exists sys init || { error_response 400 "not initialized"; return; }
  local share k progress_file shares_count master wrapped kek
  share="$(printf '%s' "$REQ_BODY" | jq -r '.share // empty')"
  [[ -n "$share" ]] || { error_response 400 "missing share"; return; }
  k="$(storage_get sys init | jq -r '.threshold')"
  progress_file="$RUNTIME_DIR/unseal.shares"
  touch "$progress_file"
  grep -qxF "$share" "$progress_file" 2>/dev/null || printf '%s\n' "$share" >> "$progress_file"
  shares_count="$(wc -l < "$progress_file" | tr -d ' ')"
  if [[ "$shares_count" -lt "$k" ]]; then
    json_response 200 "$(jq -nc --arg progress "$shares_count/$k" '{sealed:true,progress:$progress}')"
    return
  fi
  master="$(python3 "$SB_ROOT/lib/shamir.py" combine $(head -n "$k" "$progress_file"))"
  wrapped="$(storage_get sys init | jq -r '.wrapped_kek')"
  kek="$(cms_decrypt_b64 "$master" "$wrapped")"
  crypto_set_kek "$kek"
  : > "$progress_file"
  rm -f "$progress_file"
  master="$(printf '%064d' 0)"
  kek="$(printf '%064d' 0)"
  audit_append anonymous sys.unseal /v1/sys/unseal 200
  json_response 200 "$(jq -nc --arg progress "$k/$k" '{sealed:false,progress:$progress}')"
}

sys_seal() {
  require_auth || return
  require_capability sudo sys/seal || return
  crypto_purge_kek
  rm -f "$RUNTIME_DIR/unseal.shares"
  audit_append "$REQ_TOKEN_ID" sys.seal /v1/sys/seal 204
  json_response 204
}

sys_health() {
  local is_sealed leader term body
  is_sealed=false
  sealed && is_sealed=true
  consensus_refresh_leader >/dev/null 2>&1 || true
  leader="$(consensus_leader)"
  term="$(consensus_term)"
  body="$(jq -nc --argjson sealed "$is_sealed" --arg leader "$leader" --argjson term "$term" --arg node_id "$NODE_ID" \
    '{sealed:$sealed,leader:$leader,term:$term,node_id:$node_id}')"
  json_response 200 "$body"
}

internal_health() {
  local is_sealed leader term body
  is_sealed=false
  sealed && is_sealed=true
  leader="$(consensus_leader)"
  term="$(consensus_term)"
  body="$(jq -nc --argjson sealed "$is_sealed" --arg leader "$leader" --argjson term "$term" --arg node_id "$NODE_ID" \
    '{sealed:$sealed,leader:$leader,term:$term,node_id:$node_id}')"
  json_response 200 "$body"
}

secret_put() {
  local path="$1" data latest version envelope record meta
  require_unsealed || return
  require_auth || return
  require_capability write "secret/$path" || return
  require_leader_for_write || return
  data="$(printf '%s' "$REQ_BODY" | jq -c '.data')"
  [[ "$data" != "null" ]] || { error_response 400 "missing data"; return; }
  latest="$(storage_get secrets "$path/meta" 2>/dev/null | jq -r '.latest // 0' 2>/dev/null || echo 0)"
  version="$((latest + 1))"
  envelope="$(crypto_encrypt_secret "$data")"
  record="$(jq -nc --arg path "$path" --argjson version "$version" --argjson envelope "$envelope" --arg ts "$(now_iso)" \
    '{path:$path,version:$version,created_at:$ts,envelope:$envelope}')"
  meta="$(jq -nc --arg path "$path" --argjson latest "$version" '{path:$path,latest:$latest,deleted:false}')"
  replicate_put secrets "$path/$version" "$record" || { error_response 503 "no write quorum"; return; }
  replicate_put secrets "$path/meta" "$meta" || { error_response 503 "no write quorum"; return; }
  storage_put secrets "$path/$version" "$record"
  storage_put secrets "$path/meta" "$meta"
  audit_append "$REQ_TOKEN_ID" secret.write "secret/$path" 201
  json_response 201 "$(jq -nc --argjson version "$version" '{version:$version}')"
}

secret_get() {
  local path="$1" version meta record envelope data lease
  require_unsealed || return
  require_auth || return
  require_capability read "secret/$path" || return
  meta="$(storage_get secrets "$path/meta")" || { error_response 404 "secret not found"; return; }
  [[ "$(printf '%s' "$meta" | jq -r '.deleted')" == "false" ]] || { error_response 404 "secret deleted"; return; }
  version="$(query_param version)"
  [[ -n "$version" ]] || version="$(printf '%s' "$meta" | jq -r '.latest')"
  record="$(storage_get secrets "$path/$version")" || { error_response 404 "version not found"; return; }
  envelope="$(printf '%s' "$record" | jq -c '.envelope')"
  data="$(crypto_decrypt_secret "$envelope")"
  lease="$(lease_create static "secret/$path")"
  audit_append "$REQ_TOKEN_ID" secret.read "secret/$path" 200
  json_response 200 "$(jq -nc --argjson data "$data" --argjson version "$version" --argjson lease "$lease" '{data:$data,version:$version,lease:$lease}')"
}

secret_delete() {
  local path="$1" meta
  require_unsealed || return
  require_auth || return
  require_capability delete "secret/$path" || return
  require_leader_for_write || return
  meta="$(storage_get secrets "$path/meta")" || { error_response 404 "secret not found"; return; }
  meta="$(printf '%s' "$meta" | jq '.deleted=true')"
  replicate_put secrets "$path/meta" "$meta" || { error_response 503 "no write quorum"; return; }
  storage_put secrets "$path/meta" "$meta"
  audit_append "$REQ_TOKEN_ID" secret.delete "secret/$path" 204
  json_response 204
}

policy_put() {
  local name="$1" rules
  require_unsealed || return
  require_auth || return
  require_capability sudo "policies/$name" || return
  require_leader_for_write || return
  rules="$(printf '%s' "$REQ_BODY" | jq -c '.')"
  replicate_put policies "$name" "$rules" || { error_response 503 "no write quorum"; return; }
  storage_put policies "$name" "$rules"
  audit_append "$REQ_TOKEN_ID" policy.write "policies/$name" 201
  json_response 201 '{"ok":true}'
}

policy_get() {
  local name="$1" rules
  require_unsealed || return
  require_auth || return
  require_capability read "policies/$name" || return
  rules="$(storage_get policies "$name")" || { error_response 404 "policy not found"; return; }
  audit_append "$REQ_TOKEN_ID" policy.read "policies/$name" 200
  json_response 200 "$rules"
}

auth_login_route() {
  require_unsealed || return
  local username password result
  username="$(printf '%s' "$REQ_BODY" | jq -r '.username')"
  password="$(printf '%s' "$REQ_BODY" | jq -r '.password')"
  result="$(auth_login "$username" "$password")" || { audit_append anonymous auth.login /v1/auth/login 401; error_response 401 "bad credentials"; return; }
  audit_append "$(printf '%s' "$result" | jq -r '.token_id')" auth.login /v1/auth/login 200
  json_response 200 "$(printf '%s' "$result" | jq '{token,policies}')"
}

auth_token_create_route() {
  require_unsealed || return
  require_auth || return
  require_capability sudo auth/tokens || return
  require_leader_for_write || return
  local policies ttl result token_id token_record
  policies="$(printf '%s' "$REQ_BODY" | jq -c '.policies // []')"
  ttl="$(printf '%s' "$REQ_BODY" | jq -r '.ttl // 3600')"
  result="$(auth_create_token "$policies" "$ttl")"
  token_id="$(printf '%s' "$result" | jq -r '.token_id')"
  token_record="$(storage_get auth "token/$token_id")"
  replicate_put auth "token/$token_id" "$token_record" || true
  audit_append "$REQ_TOKEN_ID" auth.token_create /v1/auth/tokens 201
  json_response 201 "$(printf '%s' "$result" | jq '{token,token_id,policies}')"
}

auth_revoke_route() {
  require_unsealed || return
  require_auth || return
  require_leader_for_write || return
  local token token_id record
  token="$(printf '%s' "$REQ_BODY" | jq -r '.token')"
  token_id="$(token_id_for "$token")"
  auth_revoke_token_value "$token" || { error_response 404 "token not found"; return; }
  record="$(storage_get auth "token/$token_id")"
  replicate_put auth "token/$token_id" "$record" || true
  audit_append "$REQ_TOKEN_ID" auth.revoke /v1/auth/revoke 204
  json_response 204
}

auth_self_route() {
  require_unsealed || return
  require_auth || return
  local ttl
  ttl="$(( $(printf '%s' "$REQ_TOKEN_RECORD" | jq -r '.expires_at') - $(now_epoch) ))"
  json_response 200 "$(printf '%s' "$REQ_TOKEN_RECORD" | jq --argjson ttl "$ttl" '{token_id:.id,policies,ttl:$ttl}')"
}

dynamic_pg_route() {
  local role="$1" result
  require_unsealed || return
  require_auth || return
  require_capability read "dynamic-postgres/$role" || return
  result="$(dynamic_postgres_read "$role")" || { error_response 503 "postgres unavailable"; return; }
  audit_append "$REQ_TOKEN_ID" dynamic.read "dynamic-postgres/$role" 200
  json_response 200 "$result"
}

lease_renew_route() {
  local id="$1" result
  require_unsealed || return
  require_auth || return
  result="$(lease_renew "$id")" || { error_response 400 "lease is not renewable"; return; }
  audit_append "$REQ_TOKEN_ID" lease.renew "leases/$id" 200
  json_response 200 "$result"
}

lease_revoke_route() {
  local id="$1"
  require_unsealed || return
  require_auth || return
  lease_revoke "$id" || { error_response 404 "lease not found"; return; }
  audit_append "$REQ_TOKEN_ID" lease.revoke "leases/$id" 204
  json_response 204
}

audit_route() {
  require_unsealed || return
  require_auth || return
  require_capability read audit || return
  json_response 200 "$(audit_query "$(query_param token)")"
}

base_route() {
  local area="$1" body
  case "$area" in
    root)
      body='{"service":"strongbox","status":"ok","api":"/v1","health":"/v1/sys/health"}'
      ;;
    v1)
      body='{"service":"strongbox","version":"v1","routes":["/v1/sys","/v1/secrets","/v1/dynamic-postgres","/v1/auth","/v1/policies","/v1/leases","/v1/audit"]}'
      ;;
    sys)
      body='{"resource":"sys","routes":["GET /v1/sys/health","POST /v1/sys/init","POST /v1/sys/unseal","POST /v1/sys/seal"]}'
      ;;
    secrets)
      body='{"resource":"secrets","routes":["PUT /v1/secrets/{path}","GET /v1/secrets/{path}?version=N","DELETE /v1/secrets/{path}"]}'
      ;;
    dynamic-postgres)
      body='{"resource":"dynamic-postgres","routes":["GET /v1/dynamic-postgres/{role}"],"roles":["readonly"]}'
      ;;
    auth)
      body='{"resource":"auth","routes":["POST /v1/auth/login","POST /v1/auth/tokens","POST /v1/auth/revoke","GET /v1/auth/self"]}'
      ;;
    policies)
      body='{"resource":"policies","routes":["PUT /v1/policies/{name}","GET /v1/policies/{name}"]}'
      ;;
    leases)
      body='{"resource":"leases","routes":["POST /v1/leases/{id}/renew","POST /v1/leases/{id}/revoke"],"states":["active","expired","revoked","revocation_pending"]}'
      ;;
    audit)
      body='{"resource":"audit","routes":["GET /v1/audit?token={id}"]}'
      ;;
  esac
  json_response 200 "$body"
}

http_route() {
  case "$REQ_METHOD $REQ_PATH" in
    "GET /") base_route root ;;
    "GET /v1") base_route v1 ;;
    "GET /v1/") base_route v1 ;;
    "GET /v1/sys") base_route sys ;;
    "GET /v1/sys/") base_route sys ;;
    "GET /v1/secrets") base_route secrets ;;
    "GET /v1/secrets/") base_route secrets ;;
    "GET /v1/dynamic-postgres") base_route dynamic-postgres ;;
    "GET /v1/dynamic-postgres/") base_route dynamic-postgres ;;
    "GET /v1/auth") base_route auth ;;
    "GET /v1/auth/") base_route auth ;;
    "GET /v1/policies") base_route policies ;;
    "GET /v1/policies/") base_route policies ;;
    "GET /v1/leases") base_route leases ;;
    "GET /v1/leases/") base_route leases ;;
    "GET /v1/sys/health") sys_health ;;
    "GET /_internal/health") internal_health ;;
    "POST /v1/sys/init") sys_init ;;
    "POST /v1/sys/unseal") sys_unseal ;;
    "POST /v1/sys/seal") sys_seal ;;
    "POST /_internal/replicate") handle_internal_replicate ;;
    "POST /_internal/vote") handle_internal_vote ;;
    "POST /_internal/heartbeat") handle_internal_heartbeat ;;
    "POST /v1/auth/login") auth_login_route ;;
    "POST /v1/auth/tokens") auth_token_create_route ;;
    "POST /v1/auth/revoke") auth_revoke_route ;;
    "GET /v1/auth/self") auth_self_route ;;
    "GET /v1/audit/") base_route audit ;;
    "GET /v1/audit") audit_route ;;
    *)
      if [[ "$REQ_PATH" =~ ^/v1/secrets/(.+)$ ]]; then
        case "$REQ_METHOD" in
          PUT) secret_put "${BASH_REMATCH[1]}" ;;
          GET) secret_get "${BASH_REMATCH[1]}" ;;
          DELETE) secret_delete "${BASH_REMATCH[1]}" ;;
          *) error_response 404 "not found" ;;
        esac
      elif [[ "$REQ_PATH" =~ ^/v1/dynamic-postgres/([^/]+)$ && "$REQ_METHOD" == "GET" ]]; then
        dynamic_pg_route "${BASH_REMATCH[1]}"
      elif [[ "$REQ_PATH" =~ ^/v1/policies/([^/]+)$ ]]; then
        case "$REQ_METHOD" in
          PUT) policy_put "${BASH_REMATCH[1]}" ;;
          GET) policy_get "${BASH_REMATCH[1]}" ;;
          *) error_response 404 "not found" ;;
        esac
      elif [[ "$REQ_PATH" =~ ^/v1/leases/([^/]+)/renew$ && "$REQ_METHOD" == "POST" ]]; then
        lease_renew_route "${BASH_REMATCH[1]}"
      elif [[ "$REQ_PATH" =~ ^/v1/leases/([^/]+)/revoke$ && "$REQ_METHOD" == "POST" ]]; then
        lease_revoke_route "${BASH_REMATCH[1]}"
      else
        error_response 404 "not found"
      fi
      ;;
  esac
}

http_handle_once() {
  http_read_request || exit 0
  http_route
}
