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

consensus_init() {
  mkdir -p "$STATE_DIR/cluster"
  [[ -f "$consensus_term_file" ]] || printf '0' > "$consensus_term_file"
  [[ -f "$consensus_leader_file" ]] || printf 'node1' > "$consensus_leader_file"
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
  local leader="$1" term
  consensus_init
  term="$(( $(cat "$consensus_term_file") + 1 ))"
  printf '%s' "$term" > "$consensus_term_file"
  printf '%s' "$leader" > "$consensus_leader_file"
  printf '%s' "$leader" > "$consensus_vote_file"
}

consensus_reachable_nodes() {
  local member id url timeout
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  while read -r member; do
    id="${member%%:*}"
    url="${member#*:}"
    if [[ "$id" == "$NODE_ID" ]]; then
      echo "$id"
    elif curl -fsS --max-time "$timeout" "$url/v1/sys/health" >/dev/null 2>&1; then
      echo "$id"
    fi
  done < <(cluster_members)
}

consensus_has_quorum() {
  [[ "$(consensus_reachable_nodes | wc -l | tr -d ' ')" -ge "$(cluster_quorum)" ]]
}

consensus_refresh_leader() {
  consensus_init
  local leader leader_url timeout reachable lowest
  leader="$(consensus_leader)"
  timeout="$(config_get cluster.request_timeout_seconds 2)"
  leader_url="$(cluster_members | awk -F: -v id="$leader" '$1==id {sub($1":",""); print; exit}')"
  if [[ "$leader" == "$NODE_ID" ]] && consensus_has_quorum; then
    return 0
  fi
  if [[ -n "$leader_url" ]] && curl -fsS --max-time "$timeout" "$leader_url/v1/sys/health" >/dev/null 2>&1; then
    return 0
  fi
  consensus_has_quorum || return 1
  lowest="$(consensus_reachable_nodes | sort | head -n1)"
  consensus_set_leader "$lowest"
}

consensus_is_leader() {
  consensus_refresh_leader >/dev/null 2>&1 || true
  [[ "$(consensus_leader)" == "$NODE_ID" ]] && consensus_has_quorum
}

consensus_leader_hint_json() {
  local leader url
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
