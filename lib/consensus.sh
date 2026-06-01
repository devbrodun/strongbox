#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"
source "$SB_ROOT/lib/storage.sh"

cluster_self_url() {
  tr ',' '\n' <<< "${STRONGBOX_CLUSTER:-node1:http://127.0.0.1:${STRONGBOX_PORT:-8200}}" | awk -F: -v id="$NODE_ID" '$1==id {sub($1":",""); print; exit}'
}

cluster_members() {
  tr ',' '\n' <<< "${STRONGBOX_CLUSTER:-node1:http://127.0.0.1:${STRONGBOX_PORT:-8200}}"
}

cluster_size() {
  cluster_members | wc -l | tr -d ' '
}

cluster_quorum() {
  local n
  n="$(cluster_size)"
  echo $(( n / 2 + 1 ))
}

consensus_term_file="$STATE_DIR/cluster/current_term"
consensus_leader_file="$STATE_DIR/cluster/leader"
consensus_vote_file="$STATE_DIR/cluster/voted_for"
consensus_heartbeat_file="$STATE_DIR/cluster/last_heartbeat"

consensus_init() {
  mkdir -p "$STATE_DIR/cluster"
  [[ -f "$consensus_term_file" ]] || printf '0' > "$consensus_term_file"
  [[ -f "$consensus_leader_file" ]] || printf 'node1' > "$consensus_leader_file"
  [[ -f "$consensus_vote_file" ]] || : > "$consensus_vote_file"
  [[ -f "$consensus_heartbeat_file" ]] || printf '%s' "$(now_epoch)" > "$consensus_heartbeat_file"
}

consensus_term() {
  consensus_init
  cat "$consensus_term_file"
}

consensus_leader() {
  consensus_init
  cat "$consensus_leader_file"
}

consensus_set_leader() {
  local leader="$1" term="${2:-}"
  consensus_init
  if [[ -z "$term" ]]; then
    term="$(( $(cat "$consensus_term_file") + 1 ))"
  fi
  printf '%s' "$term" > "$consensus_term_file"
  printf '%s' "$leader" > "$consensus_leader_file"
  printf '%s' "$leader" > "$consensus_vote_file"
  printf '%s' "$(now_epoch)" > "$consensus_heartbeat_file"
}

consensus_last_heartbeat() {
  consensus_init
  cat "$consensus_heartbeat_file"
}

consensus_record_heartbeat() {
  consensus_init
  printf '%s' "$(now_epoch)" > "$consensus_heartbeat_file"
}

consensus_timeout_seconds() {
  local timeout_ms
  timeout_ms="$(config_get cluster.election_timeout_ms 2500)"
  echo $(( (timeout_ms + 999) / 1000 ))
}

consensus_heartbeat_seconds() {
  local heartbeat_ms
  heartbeat_ms="$(config_get cluster.heartbeat_interval_ms 800)"
  echo $(( (heartbeat_ms + 999) / 1000 ))
}

consensus_reachable_nodes() {
  local member id url timeout
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    if [[ "$id" == "$NODE_ID" ]]; then
      echo "$id"
    elif curl -fsS --max-time "$timeout" "$url/_internal/health" >/dev/null 2>&1; then
      echo "$id"
    fi
  done < <(cluster_members)
}

consensus_has_quorum() {
  [[ "$(consensus_reachable_nodes | wc -l | tr -d ' ')" -ge "$(cluster_quorum)" ]]
}

consensus_discover_leader() {
  local member id url timeout resp discovered best_leader best_term current_term current_leader
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  current_term="$(consensus_term)"
  current_leader="$(consensus_leader)"
  best_term="$current_term"
  best_leader="$current_leader"
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    [[ "$id" == "$NODE_ID" ]] && continue
    resp="$(curl -fsS --max-time "$timeout" "$url/_internal/health" 2>/dev/null || true)"
    [[ -n "$resp" ]] || continue
    discovered="$(printf '%s' "$resp" | jq -r '.leader // empty')"
    [[ -n "$discovered" ]] || continue
    term="$(printf '%s' "$resp" | jq -r '.term // 0')"
    if [[ "$term" -gt "$best_term" ]] || { [[ "$term" -eq "$best_term" ]] && [[ -n "$discovered" ]] && [[ "$discovered" != "$best_leader" ]]; }; then
      best_term="$term"
      best_leader="$discovered"
    fi
  done < <(cluster_members)
  if [[ "$best_term" -gt "$current_term" ]] || { [[ "$best_term" -eq "$current_term" ]] && [[ -n "$best_leader" ]] && [[ "$best_leader" != "$current_leader" ]]; }; then
    consensus_set_leader "$best_leader" "$best_term"
    return 0
  fi
  return 1
}

consensus_refresh_leader() {
  consensus_init
  local leader leader_url timeout elapsed lowest
  leader="$(consensus_leader)"
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  leader_url="$(cluster_members | awk -F: -v id="$leader" '$1==id {sub($1":",""); print; exit}')"
  if [[ "$leader" != "$NODE_ID" ]] && [[ -n "$leader_url" ]] && curl -fsS --max-time "$timeout" "$leader_url/_internal/health" >/dev/null 2>&1; then
    return 0
  fi
  consensus_discover_leader && return 0
  if [[ "$leader" == "$NODE_ID" ]] && consensus_has_quorum; then
    return 0
  fi
  elapsed="$(( $(now_epoch) - $(consensus_last_heartbeat) ))"
  [[ "$elapsed" -ge "$(consensus_timeout_seconds)" ]] || return 1
  consensus_has_quorum || return 1
  lowest="$(consensus_reachable_nodes | sort | head -n1)"
  [[ "$lowest" == "$NODE_ID" ]] || return 1
  consensus_start_election
}

consensus_is_leader() {
  consensus_refresh_leader >/dev/null 2>&1 || true
  [[ "$(consensus_leader)" == "$NODE_ID" ]] && consensus_has_quorum
}

consensus_leader_hint_json() {
  local leader url
  consensus_refresh_leader >/dev/null 2>&1 || true
  leader="$(consensus_leader)"
  url="$(cluster_members | awk -F: -v id="$leader" '$1==id {sub($1":",""); print; exit}')"
  jq -nc --arg leader "$leader" --arg url "$url" '{leader:$leader,leader_url:$url}'
}

consensus_replicate() {
  local payload="$1" ok=1 member id url timeout
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    [[ "$id" == "$NODE_ID" ]] && continue
    if curl -fsS --max-time "$timeout" -X POST "$url/_internal/replicate" \
      -H 'Content-Type: application/json' \
      -H "X-StrongBox-Node: $NODE_ID" \
      -d "$payload" >/dev/null 2>&1; then
      ok=$((ok + 1))
    fi
  done < <(cluster_members)
  [[ "$ok" -ge "$(cluster_quorum)" ]]
}

consensus_handle_vote_request() {
  local payload="$1" term candidate current voted_for
  candidate="$(printf '%s' "$payload" | jq -r '.candidate // empty')"
  term="$(printf '%s' "$payload" | jq -r '.term // 0')"
  [[ -n "$candidate" ]] || { jq -nc --argjson term "$(consensus_term)" '{granted:false,term:$term}'; return; }
  consensus_init
  current="$(consensus_term)"
  voted_for="$(cat "$consensus_vote_file" 2>/dev/null || true)"
  if [[ "$term" -gt "$current" ]]; then
    printf '%s' "$term" > "$consensus_term_file"
    : > "$consensus_vote_file"
    current="$term"
    voted_for=""
  fi
  if [[ "$term" -eq "$current" && ( -z "$voted_for" || "$voted_for" == "$candidate" ) ]]; then
    printf '%s' "$candidate" > "$consensus_vote_file"
    consensus_record_heartbeat
    jq -nc --argjson term "$current" --arg candidate "$candidate" '{granted:true,term:$term,candidate:$candidate}'
  else
    jq -nc --argjson term "$current" --arg candidate "$candidate" '{granted:false,term:$term,candidate:$candidate}'
  fi
}

consensus_handle_heartbeat() {
  local payload="$1" term leader current
  leader="$(printf '%s' "$payload" | jq -r '.leader // empty')"
  term="$(printf '%s' "$payload" | jq -r '.term // 0')"
  [[ -n "$leader" ]] || { jq -nc --argjson term "$(consensus_term)" '{ok:false,term:$term}'; return; }
  consensus_init
  current="$(consensus_term)"
  if [[ "$term" -ge "$current" ]]; then
    printf '%s' "$term" > "$consensus_term_file"
    printf '%s' "$leader" > "$consensus_leader_file"
    printf '%s' "$leader" > "$consensus_vote_file"
    consensus_record_heartbeat
    jq -nc --argjson term "$term" --arg leader "$leader" '{ok:true,term:$term,leader:$leader}'
  else
    jq -nc --argjson term "$current" --arg leader "$leader" '{ok:false,term:$term,leader:$leader}'
  fi
}

consensus_broadcast_heartbeat() {
  local leader term payload member id url timeout ok=0
  leader="$(consensus_leader)"
  term="$(consensus_term)"
  payload="$(jq -nc --arg leader "$leader" --argjson term "$term" '{leader:$leader,term:$term}')"
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  consensus_record_heartbeat
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    [[ "$id" == "$NODE_ID" ]] && continue
    curl -fsS --max-time "$timeout" -X POST "$url/_internal/heartbeat" \
      -H 'Content-Type: application/json' \
      -H "X-StrongBox-Node: $NODE_ID" \
      -d "$payload" >/dev/null 2>&1 && ok=$((ok + 1))
  done < <(cluster_members)
  return 0
}

consensus_request_votes() {
  local term="$1" payload member id url timeout votes=1 resp
  payload="$(jq -nc --arg candidate "$NODE_ID" --argjson term "$term" '{candidate:$candidate,term:$term}')"
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    [[ "$id" == "$NODE_ID" ]] && continue
    resp="$(curl -fsS --max-time "$timeout" -X POST "$url/_internal/vote" \
      -H 'Content-Type: application/json' \
      -H "X-StrongBox-Node: $NODE_ID" \
      -d "$payload" 2>/dev/null || true)"
    [[ "$(printf '%s' "$resp" | jq -r '.granted // false')" == "true" ]] && votes=$((votes + 1))
  done < <(cluster_members)
  [[ "$votes" -ge "$(cluster_quorum)" ]]
}

consensus_start_election() {
  local current term
  current="$(consensus_term)"
  term="$(( current + 1 ))"
  printf '%s' "$term" > "$consensus_term_file"
  printf '%s' "$NODE_ID" > "$consensus_vote_file"
  if consensus_request_votes "$term"; then
    consensus_set_leader "$NODE_ID" "$term"
    consensus_broadcast_heartbeat
    return 0
  fi
  return 1
}

consensus_run_loop() {
  local heartbeat_delay election_delay
  heartbeat_delay="$(consensus_heartbeat_seconds)"
  election_delay="$(consensus_timeout_seconds)"
  while true; do
    if [[ "$(consensus_leader)" == "$NODE_ID" ]] && consensus_has_quorum; then
      consensus_broadcast_heartbeat
      sleep "$heartbeat_delay"
    else
      consensus_refresh_leader >/dev/null 2>&1 || true
      sleep "$election_delay"
    fi
  done
}
