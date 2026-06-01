#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"

storage_put() {
  local ns="$1" key="$2" value="$3"
  printf '%s' "$value" | atomic_write "$(key_file "$ns" "$key")"
}

storage_get() {
  local ns="$1" key="$2" file
  file="$(key_file "$ns" "$key")"
  [[ -f "$file" ]] || return 1
  cat "$file"
}

storage_delete() {
  local ns="$1" key="$2" file
  file="$(key_file "$ns" "$key")"
  [[ -f "$file" ]] && rm -f "$file"
}

storage_exists() {
  local ns="$1" key="$2"
  [[ -f "$(key_file "$ns" "$key")" ]]
}

storage_list() {
  local ns="$1"
  local dir="$STATE_DIR/$ns"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f -name '*.json' -print
}

storage_cas() {
  local ns="$1" key="$2" expected="$3" value="$4" file current
  file="$(key_file "$ns" "$key")"
  current=""
  [[ -f "$file" ]] && current="$(cat "$file")"
  [[ "$current" == "$expected" ]] || return 1
  storage_put "$ns" "$key" "$value"
}
