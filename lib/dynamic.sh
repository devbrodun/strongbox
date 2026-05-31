#!/usr/bin/env bash
# lib/dynamic.sh — Dynamic PostgreSQL credential engine
# OWNER: Person 3 (Leases & Dynamic Postgres)

set -euo pipefail

STRONGBOX_PG_HOST="${STRONGBOX_PG_HOST:-localhost}"
STRONGBOX_PG_PORT="${STRONGBOX_PG_PORT:-5432}"
STRONGBOX_PG_DB="${STRONGBOX_PG_DB:-postgres}"
STRONGBOX_PG_USER="${STRONGBOX_PG_USER:-postgres}"
STRONGBOX_PG_PASS="${STRONGBOX_PG_PASS:-}"
STRONGBOX_PG_GRANT="${STRONGBOX_PG_GRANT:-SELECT ON ALL TABLES IN SCHEMA public}"

# Internal helper to execute SQL via psql. Returns 2 on connection failure.
_dynamic_pg_exec() {
    local sql="${1:?}"
    local exit_code=0
    local err_file
    err_file=$(mktemp)

    PGPASSWORD="${STRONGBOX_PG_PASS:-}" psql \
        -h "$STRONGBOX_PG_HOST" \
        -p "$STRONGBOX_PG_PORT" \
        -U "$STRONGBOX_PG_USER" \
        -d "$STRONGBOX_PG_DB" \
        -c "$sql" >/dev/null 2>"$err_file" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        local err_msg
        err_msg=$(cat "$err_file")
        rm -f "$err_file"
        echo "ERROR: pg_exec failed (exit $exit_code): $err_msg" >&2
        
        # Check for standard connection/unreachable errors
        if [[ "$err_msg" == *"could not connect"* || "$err_msg" == *"connection refused"* || "$err_msg" == *"timeout expired"* || "$err_msg" == *"is the server running"* ]]; then
            return 2
        fi
        return 1
    fi

    rm -f "$err_file"
    return 0
}

# Generate a safe random username: sb_<role>_<random8>
_dynamic_gen_username() {
    local role_name="${1:?}"
    local rand
    rand=$(_crypto_random_hex 4)
    local clean_role
    clean_role=$(echo "$role_name" | tr -cd 'a-zA-Z0-9_')
    echo "sb_${clean_role}_${rand}"
}

# Generate a 24-char random password
_dynamic_gen_password() {
    _crypto_random_hex 12
}

# Provision a fresh PostgreSQL role with requested grant and a lease
dynamic_postgres_read() {
    local role_name="${1:?role_name required}"

    local username
    username=$(_dynamic_gen_username "$role_name")
    local password
    password=$(_dynamic_gen_password)

    # 1. Create the role with login permissions
    if ! _dynamic_pg_exec "CREATE ROLE $username WITH LOGIN PASSWORD '$password';"; then
        echo "ERROR: failed to create PG role $username" >&2
        return 1
    fi

    # 2. Grant requested privileges
    # Note: STRONGBOX_PG_GRANT can contain multiple statements, but typically is one.
    # We do a direct injection here because this is an administrative template query.
    if ! _dynamic_pg_exec "GRANT $STRONGBOX_PG_GRANT TO $username;"; then
        echo "ERROR: failed to grant privileges to PG role $username" >&2
        # Clean up role before failing
        _dynamic_pg_exec "DROP ROLE IF EXISTS $username;" || true
        return 1
    fi

    # 3. Issue a lease for tracking
    local lease_json
    lease_json=$(lease_create "dynamic-postgres/$role_name" "$STRONGBOX_LEASE_TTL" "$STRONGBOX_LEASE_MAX" "$username")

    # 4. Format and return output JSON
    jq -n \
        --arg username "$username" \
        --arg password "$password" \
        --argjson lease "$lease_json" \
        '{username: $username, password: $password, lease: $lease}'
}

# Revoke dynamic PostgreSQL role
dynamic_revoke_credential() {
    local username="${1:?}"
    local lease_id="${2:?}"

    echo "[dynamic-postgres] revoking role $username for lease $lease_id..." >&2

    # PostgreSQL role teardown sequence
    local sql_commands=(
        "REASSIGN OWNED BY $username TO \"$STRONGBOX_PG_USER\";"
        "DROP OWNED BY $username;"
        "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM $username;"
        "REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM $username;"
        "REVOKE ALL PRIVILEGES ON SCHEMA public FROM $username;"
        "DROP ROLE IF EXISTS $username;"
    )

    local exit_code=0
    for sql in "${sql_commands[@]}"; do
        _dynamic_pg_exec "$sql" || exit_code=$?
        if [[ "$exit_code" -eq 2 ]]; then
            # Connection failed - propagate 2 so reaper triggers backoff
            return 2
        fi
    done

    return 0
}

# Route handler: GET /v1/dynamic-postgres/{role}
handle_dynamic_postgres_read() {
    local role_name="${1:?}"
    local token="${2:-}"

    if [[ "${STRONGBOX_SEALED:-true}" == "true" ]]; then
        http_respond 503 '{"error":"vault is sealed"}'
        return
    fi

    if ! auth_validate_token "$token" "dynamic-postgres/$role_name" "read"; then
        http_respond 403 '{"error":"forbidden"}'
        return
    fi

    # Forward to leader if we're a follower
    if ! consensus_is_leader; then
        local leader_addr
        leader_addr=$(consensus_leader_addr)
        http_respond 307 "{\"error\":\"not leader\",\"leader\":\"${leader_addr}\"}"
        return
    fi

    resp=$(dynamic_postgres_read "$role_name") || {
        http_respond 500 '{"error":"dynamic role provisioning failed"}'
        return
    }

    audit_append "dynamic-postgres" "$token" "read" "dynamic-postgres/${role_name}" "success"
    http_respond 200 "$resp"
}

