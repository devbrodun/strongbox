#!/usr/bin/env bash
# lib/audit.sh — HMAC-SHA256 chained tamper-evident audit log
# OWNER: Person 2 (Auth, Policies & Audit)

set -euo pipefail

STRONGBOX_AUDIT_LOG="${STRONGBOX_AUDIT_LOG:-/var/lib/strongbox/audit.log}"
STRONGBOX_AUDIT_SECRET="${STRONGBOX_AUDIT_SECRET:-}"  # must be set before use

# Internal helper to read last entry's hash
_audit_prev_hash() {
    if [[ ! -f "$STRONGBOX_AUDIT_LOG" || ! -s "$STRONGBOX_AUDIT_LOG" ]]; then
        echo "0000000000000000000000000000000000000000000000000000000000000000"
        return
    fi
    local last_line
    last_line=$(tail -n 1 "$STRONGBOX_AUDIT_LOG")
    local hash
    hash=$(echo "$last_line" | jq -r '.entry_hash' 2>/dev/null)
    if [[ -z "$hash" || "$hash" == "null" ]]; then
        echo "0000000000000000000000000000000000000000000000000000000000000000"
    else
        echo "$hash"
    fi
}

# Append one JSON entry to STRONGBOX_AUDIT_LOG
audit_append() {
    local module="${1:-}"
    local token_id="${2:-none}"
    local op="${3:-}"
    local path="${4:-}"
    local result="${5:-}"

    # Skip if audit secret is not set yet (pre-init/unseal)
    if [[ -z "${STRONGBOX_AUDIT_SECRET:-}" ]]; then
        return 0
    fi

    local ts
    ts=$(date +%s)

    local prev_hash
    prev_hash=$(_audit_prev_hash)

    # Calculate HMAC: prev_hash || ts || token || op || path || result
    local data_to_sign="${prev_hash}|${ts}|${token_id}|${op}|${path}|${result}"
    local entry_hash
    entry_hash=$(echo -n "$data_to_sign" | openssl dgst -sha256 -hmac "$STRONGBOX_AUDIT_SECRET" | awk '{print $NF}')

    # Construct JSON entry
    local entry_json
    entry_json=$(jq -c -n \
        --argjson ts "$ts" \
        --arg token "$token_id" \
        --arg op "$op" \
        --arg path "$path" \
        --arg result "$result" \
        --arg prev_hash "$prev_hash" \
        --arg entry_hash "$entry_hash" \
        '{ts: $ts, token: $token, op: $op, path: $path, result: $result, prev_hash: $prev_hash, entry_hash: $entry_hash}')

    mkdir -p "$(dirname "$STRONGBOX_AUDIT_LOG")"
    echo "$entry_json" >> "$STRONGBOX_AUDIT_LOG"
}

# Print JSON array of entries filtered by token
audit_get() {
    local token_id="${1:?token required}"
    if [[ ! -f "$STRONGBOX_AUDIT_LOG" ]]; then
        echo "[]"
        return
    fi
    jq -s --arg tok "$token_id" 'map(select(.token == $tok))' "$STRONGBOX_AUDIT_LOG" 2>/dev/null || echo "[]"
}

# Route handler: GET /v1/audit?token=xxx
handle_audit_query() {
    local query_token="${1:-}"
    local token="${_HTTP_TOKEN:-}"

    if [[ "${STRONGBOX_SEALED:-true}" == "true" ]]; then
        http_respond 503 '{"error":"vault is sealed"}'
        return
    fi

    if ! auth_validate_token "$token" "audit" "read"; then
        http_respond 403 '{"error":"forbidden"}'
        return
    fi

    if [[ -z "$query_token" ]]; then
        http_respond 400 '{"error":"missing token query parameter"}'
        return
    fi

    local resp
    resp=$(audit_get "$query_token")
    http_respond 200 "$resp"
}

