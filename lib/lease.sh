#!/usr/bin/env bash
# lib/lease.sh — Lease lifecycle management + background reaper
# OWNER: Person 3 (Leases & Dynamic Postgres)

set -euo pipefail

STRONGBOX_DATA_DIR="${STRONGBOX_DATA_DIR:-/var/lib/strongbox}"
_LEASES_DIR="${STRONGBOX_DATA_DIR}/leases"

# Create a new lease and store it in _LEASES_DIR
lease_create() {
    local path="${1:?path required}"
    local ttl="${2:?ttl required}"
    local max_ttl="${3:?max_ttl required}"
    local username="${4:-}"

    local lease_id
    lease_id=$(_crypto_random_hex 16)

    local current_time
    current_time=$(date +%s)

    local expires_at=$(( current_time + ttl ))
    local max_expires_at=$(( current_time + max_ttl ))

    # Create lease JSON
    local lease_json
    lease_json=$(jq -n \
        --arg id "$lease_id" \
        --arg path "$path" \
        --argjson ttl "$ttl" \
        --argjson max_ttl "$max_ttl" \
        --argjson expires_at "$expires_at" \
        --argjson max_expires_at "$max_expires_at" \
        --arg state "active" \
        --arg username "$username" \
        --argjson retry_count 0 \
        --argjson next_retry_at 0 \
        '{id: $id, path: $path, ttl: $ttl, max_ttl: $max_ttl, expires_at: $expires_at, max_expires_at: $max_expires_at, state: $state, username: $username, retry_count: $retry_count, next_retry_at: $next_retry_at}')

    mkdir -p "$_LEASES_DIR"
    printf '%s' "$lease_json" > "${_LEASES_DIR}/${lease_id}"

    # Propagate state to followers if consensus is active
    if [[ "$(type -t consensus_sync_state)" == "function" ]]; then
        consensus_sync_state || true
    fi

    echo "$lease_json"
}

# Extend an active lease's TTL
lease_renew() {
    local lease_id="${1:?lease_id required}"
    local body="${2:-}"

    if [[ ! -f "${_LEASES_DIR}/${lease_id}" ]]; then
        echo "ERROR: lease not found" >&2
        return 1
    fi

    local lease_json
    lease_json=$(cat "${_LEASES_DIR}/${lease_id}")

    local state
    state=$(echo "$lease_json" | jq -r '.state')
    if [[ "$state" != "active" ]]; then
        echo "ERROR: lease is not active (state=$state)" >&2
        return 1
    fi

    local expires_at
    expires_at=$(echo "$lease_json" | jq -r '.expires_at')
    local max_expires_at
    max_expires_at=$(echo "$lease_json" | jq -r '.max_expires_at')

    local current_time
    current_time=$(date +%s)

    if [[ "$current_time" -ge "$expires_at" ]]; then
        echo "ERROR: lease already expired" >&2
        return 1
    fi

    if [[ "$current_time" -ge "$max_expires_at" ]]; then
        echo "ERROR: lease reached max TTL" >&2
        return 1
    fi

    # Extract increment from JSON body
    local increment=""
    if [[ -n "$body" ]]; then
        increment=$(echo "$body" | jq -r '.increment' 2>/dev/null)
    fi
    if [[ -z "$increment" || "$increment" == "null" ]]; then
        increment=$(echo "$lease_json" | jq -r '.ttl')
    fi

    local new_expires_at=$(( current_time + increment ))
    if [[ "$new_expires_at" -gt "$max_expires_at" ]]; then
        new_expires_at="$max_expires_at"
    fi

    # Update lease JSON
    lease_json=$(echo "$lease_json" | jq --argjson expires_at "$new_expires_at" '.expires_at = $expires_at')
    printf '%s' "$lease_json" > "${_LEASES_DIR}/${lease_id}"

    if [[ "$(type -t consensus_sync_state)" == "function" ]]; then
        consensus_sync_state || true
    fi

    echo "$lease_json"
}

# Revoke a lease immediately
lease_revoke() {
    local lease_id="${1:?lease_id required}"

    if [[ ! -f "${_LEASES_DIR}/${lease_id}" ]]; then
        echo "ERROR: lease not found" >&2
        return 1
    fi

    local lease_json
    lease_json=$(cat "${_LEASES_DIR}/${lease_id}")

    local username
    username=$(echo "$lease_json" | jq -r '.username')
    local current_time
    current_time=$(date +%s)

    if [[ -n "$username" && "$username" != "null" && "$username" != "" ]]; then
        # This is a dynamic Postgres credential, so drop the role
        if ! dynamic_revoke_credential "$username" "$lease_id"; then
            # Revocation failed (likely DB unreachable)
            # Apply exponential backoff
            local retry_count
            retry_count=$(echo "$lease_json" | jq -r '.retry_count')
            retry_count=$(( retry_count + 1 ))

            local delay=$(( 2 ** retry_count ))
            if [[ "$delay" -gt 60 ]]; then
                delay=60
            fi
            local next_retry_at=$(( current_time + delay ))

            lease_json=$(echo "$lease_json" | jq \
                --arg state "revocation_pending" \
                --argjson retry_count "$retry_count" \
                --argjson next_retry_at "$next_retry_at" \
                '.state = $state | .retry_count = $retry_count | .next_retry_at = $next_retry_at')
            printf '%s' "$lease_json" > "${_LEASES_DIR}/${lease_id}"

            if [[ "$(type -t consensus_sync_state)" == "function" ]]; then
                consensus_sync_state || true
            fi
            return 2
        fi
    fi

    # Successfully revoked!
    lease_json=$(echo "$lease_json" | jq --arg state "revoked" '.state = $state')
    printf '%s' "$lease_json" > "${_LEASES_DIR}/${lease_id}"

    if [[ "$(type -t consensus_sync_state)" == "function" ]]; then
        consensus_sync_state || true
    fi

    return 0
}

# Retrieve a lease JSON
lease_get() {
    local lease_id="${1:?lease_id required}"
    if [[ ! -f "${_LEASES_DIR}/${lease_id}" ]]; then
        return 1
    fi
    cat "${_LEASES_DIR}/${lease_id}"
}

# Start background reaper
lease_reaper_start() {
    _lease_reaper_loop &
}

# Background reaper loop calling direct logic via Zero-Self-Call architecture
_lease_reaper_loop() {
    sleep 2
    while true; do
        if [[ "$(type -t consensus_load_state)" == "function" ]]; then
            consensus_load_state || true
        fi

        if [[ "${STRONGBOX_SEALED:-true}" != "true" && "${_CONSENSUS_ROLE:-follower}" == "leader" ]]; then
            # Override http_respond to be a no-op inside this background loop
            http_respond() { :; }
            handle_lease_reap >/dev/null 2>&1 || true
        fi
        sleep 5
    done
}

# Reap all expired or retry-pending leases (executed in main process)
handle_lease_reap() {
    local current_time
    current_time=$(date +%s)

    if [[ -d "$_LEASES_DIR" ]]; then
        for lfile in "${_LEASES_DIR}"/*; do
            [[ ! -f "$lfile" ]] && continue
            local lease_id; lease_id=$(basename "$lfile")
            local lease_json; lease_json=$(cat "$lfile")
            local state
            state=$(echo "$lease_json" | jq -r '.state')
            local expires_at
            expires_at=$(echo "$lease_json" | jq -r '.expires_at')

            if [[ "$state" == "active" ]]; then
                if [[ "$current_time" -ge "$expires_at" ]]; then
                    echo "[reaper] lease $lease_id expired, revoking..." >&2
                    lease_revoke "$lease_id" || true
                fi
            elif [[ "$state" == "revocation_pending" ]]; then
                local next_retry_at
                next_retry_at=$(echo "$lease_json" | jq -r '.next_retry_at')
                if [[ "$current_time" -ge "$next_retry_at" ]]; then
                    echo "[reaper] retrying revocation for lease $lease_id..." >&2
                    lease_revoke "$lease_id" || true
                fi
            fi
        done
    fi

    http_respond 200 '{"status":"reap completed"}'
}
