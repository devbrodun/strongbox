#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"
source "$SB_ROOT/lib/storage.sh"

lease_create() {
  local kind="$1" path="$2" ttl="${3:-$(config_get leases.default_ttl_seconds 60)}" metadata="${4:-}"
  local max id now expires record metadata_json
  [[ -n "$metadata" ]] || metadata='{}'
  max="$(config_get leases.max_ttl_seconds 300)"
  [[ "$ttl" -le "$max" ]] || ttl="$max"
  metadata_json="$(printf '%s' "$metadata" | jq -c . 2>/dev/null || true)"
  [[ -n "$metadata_json" ]] || metadata_json='{}'
  id="$(uuidgen)"
  now="$(now_epoch)"
  expires="$((now + ttl))"
  record="$(jq -nc --arg id "$id" --arg kind "$kind" --arg path "$path" --arg state active \
    --argjson created "$now" --argjson expires "$expires" --argjson ttl "$ttl" --argjson max_ttl "$max" --argjson metadata "$metadata_json" \
    '{id:$id,kind:$kind,path:$path,state:$state,created_at:$created,expires_at:$expires,ttl:$ttl,max_ttl:$max_ttl,metadata:$metadata,retry_count:0,next_retry_at:0}')"
  [[ -n "$record" ]] || return 1
  storage_put leases "$id" "$record"
  jq -nc --arg id "$id" --arg state active --argjson ttl "$ttl" '{id:$id,state:$state,ttl:$ttl}'
}

lease_get() {
  storage_get leases "$1"
}

lease_set_state() {
  local id="$1" state="$2" record
  record="$(lease_get "$id")" || return 1
  storage_put leases "$id" "$(printf '%s' "$record" | jq --arg state "$state" '.state=$state | .updated_at=(now|floor)')"
}

lease_renew() {
  local id="$1" add="${2:-$(config_get leases.default_ttl_seconds 60)}" record now created max new_exp
  record="$(lease_get "$id")" || return 1
  now="$(now_epoch)"
  [[ "$(printf '%s' "$record" | jq -r '.state')" == "active" ]] || return 2
  [[ "$(printf '%s' "$record" | jq -r '.expires_at')" -gt "$now" ]] || return 2
  created="$(printf '%s' "$record" | jq -r '.created_at')"
  max="$(printf '%s' "$record" | jq -r '.max_ttl')"
  new_exp="$(( now + add ))"
  [[ "$new_exp" -le "$(( created + max ))" ]] || new_exp="$(( created + max ))"
  storage_put leases "$id" "$(printf '%s' "$record" | jq --argjson exp "$new_exp" '.expires_at=$exp | .ttl=($exp-(now|floor))')"
  jq -nc --argjson new_ttl "$(( new_exp - now ))" '{new_ttl:$new_ttl}'
}

lease_revoke() {
  local id="$1" record kind
  record="$(lease_get "$id")" || return 1
  kind="$(printf '%s' "$record" | jq -r '.kind')"
  if [[ "$kind" == "dynamic-postgres" ]]; then
    dynamic_revoke_postgres_lease "$record" && lease_set_state "$id" revoked || lease_mark_pending "$record"
  else
    lease_set_state "$id" revoked
  fi
}

lease_mark_pending() {
  local record="$1" id retry next
  id="$(printf '%s' "$record" | jq -r '.id')"
  retry="$(printf '%s' "$record" | jq -r '.retry_count + 1')"
  next="$(( $(now_epoch) + (2 ** retry) ))"
  storage_put leases "$id" "$(printf '%s' "$record" | jq --argjson retry "$retry" --argjson next "$next" '.state="revocation_pending" | .retry_count=$retry | .next_retry_at=$next | .updated_at=(now|floor)')"
}

lease_reap_once() {
  local file record id state expires now kind next
  now="$(now_epoch)"
  while read -r file; do
    record="$(cat "$file")"
    id="$(printf '%s' "$record" | jq -r '.id')"
    state="$(printf '%s' "$record" | jq -r '.state')"
    expires="$(printf '%s' "$record" | jq -r '.expires_at')"
    kind="$(printf '%s' "$record" | jq -r '.kind')"
    if [[ "$state" == "active" && "$expires" -le "$now" ]]; then
      if [[ "$kind" == "dynamic-postgres" ]]; then
        dynamic_revoke_postgres_lease "$record" && lease_set_state "$id" expired || lease_mark_pending "$record"
      else
        lease_set_state "$id" expired
      fi
    elif [[ "$state" == "revocation_pending" ]]; then
      next="$(printf '%s' "$record" | jq -r '.next_retry_at')"
      if [[ "$next" -le "$now" ]]; then
        dynamic_revoke_postgres_lease "$record" && lease_set_state "$id" expired || lease_mark_pending "$record"
      fi
    fi
  done < <(storage_list leases)
}

lease_reaper_loop() {
  local interval
  interval="$(config_get leases.reap_interval_seconds 3)"
  while true; do
    lease_reap_once || true
    sleep "$interval"
  done
}
