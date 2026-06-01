#!/usr/bin/env bash

set -euo pipefail

SB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STRONGBOX_STATE_DIR:-/var/lib/strongbox}"
AUDIT_LOG="${STRONGBOX_AUDIT_LOG:-/var/log/strongbox/audit.log}"
NODE_ID="${STRONGBOX_NODE_ID:-node1}"
CONFIG_FILE="${STRONGBOX_CONFIG:-$SB_ROOT/config.yaml}"
RUNTIME_DIR="/dev/shm/strongbox-${NODE_ID}"

mkdir -p "$STATE_DIR" "$(dirname "$AUDIT_LOG")" "$RUNTIME_DIR"

die() {
  echo "strongbox: $*" >&2
  exit 1
}

now_epoch() {
  date +%s
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

rand_hex() {
  openssl rand -hex "$1"
}

rand_b64url() {
  openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'
}

json_escape() {
  jq -Rs .
}

json_response() {
  local status="$1"
  local body="${2:-}"
  [[ -n "$body" ]] || body='{}'
  local reason="OK"
  case "$status" in
    200) reason="OK" ;;
    201) reason="Created" ;;
    204) reason="No Content" ;;
    400) reason="Bad Request" ;;
    401) reason="Unauthorized" ;;
    403) reason="Forbidden" ;;
    404) reason="Not Found" ;;
    409) reason="Conflict" ;;
    500) reason="Internal Server Error" ;;
    503) reason="Service Unavailable" ;;
  esac
  if [[ "$status" == "204" ]]; then
    printf 'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
  else
    local len
    len="$(printf '%s' "$body" | wc -c | tr -d ' ')"
    printf 'HTTP/1.1 %s %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$status" "$reason" "$len" "$body"
  fi
}

error_response() {
  local status="$1" message="$2"
  json_response "$status" "$(jq -nc --arg error "$message" '{error:$error}')"
}

config_get() {
  local dotted="$1" default="${2:-}"
  case "$dotted" in
    seal.threshold) awk '/^seal:/{s=1;next} /^[a-zA-Z]/{s=0} s && /threshold:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    seal.shares) awk '/^seal:/{s=1;next} /^[a-zA-Z]/{s=0} s && /shares:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    leases.default_ttl_seconds) awk '/^leases:/{s=1;next} /^[a-zA-Z]/{s=0} s && /default_ttl_seconds:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    leases.max_ttl_seconds) awk '/^leases:/{s=1;next} /^[a-zA-Z]/{s=0} s && /max_ttl_seconds:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    leases.reap_interval_seconds) awk '/^leases:/{s=1;next} /^[a-zA-Z]/{s=0} s && /reap_interval_seconds:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    cluster.election_timeout_ms) awk '/^cluster:/{s=1;next} /^[a-zA-Z]/{s=0} s && /election_timeout_ms:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    cluster.heartbeat_interval_ms) awk '/^cluster:/{s=1;next} /^[a-zA-Z]/{s=0} s && /heartbeat_interval_ms:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    cluster.request_timeout_seconds) awk '/^cluster:/{s=1;next} /^[a-zA-Z]/{s=0} s && /request_timeout_seconds:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.host) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /host:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.port) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /port:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.database) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /database:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.admin_user) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /admin_user:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.admin_password) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /admin_password:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    postgres.readonly_grants) awk '/^postgres:/{s=1;next} /^[a-zA-Z]/{s=0} s && /readonly_grants:/{sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit}' "$CONFIG_FILE" 2>/dev/null || true ;;
    *) true ;;
  esac | {
    read -r value || true
    if [[ -n "${value:-}" ]]; then printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
  }
}

key_file() {
  local ns="$1" key="$2"
  local safe
  safe="$(printf '%s' "$key" | base64 | tr '+/' '-_' | tr -d '=\n')"
  printf '%s/%s/%s.json\n' "$STATE_DIR" "$ns" "$safe"
}

atomic_write() {
  local file="$1"
  local dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="${file}.$$.$RANDOM.tmp"
  cat > "$tmp"
  mv "$tmp" "$file"
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}
