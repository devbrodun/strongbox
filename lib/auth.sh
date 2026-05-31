#!/usr/bin/env bash
# lib/auth.sh — Token auth, Argon2id passwords, policy engine
# OWNER: Person 2 (Auth, Policies & Audit)

set -euo pipefail

STRONGBOX_DATA_DIR="${STRONGBOX_DATA_DIR:-/var/lib/strongbox}"
_AUTH_TOKENS_DIR="${STRONGBOX_DATA_DIR}/auth/tokens"
_AUTH_USERS_DIR="${STRONGBOX_DATA_DIR}/auth/users"
_AUTH_USER_POLICIES_DIR="${STRONGBOX_DATA_DIR}/auth/user_policies"
_AUTH_POLICIES_DIR="${STRONGBOX_DATA_DIR}/policies"
_AUTH_REVOKED_DIR="${STRONGBOX_DATA_DIR}/auth/revoked"

# Declare global associative arrays for backward compatibility with memory-based testing
declare -g -A _AUTH_TOKENS=() 2>/dev/null || true
declare -g -A _AUTH_USERS=() 2>/dev/null || true
declare -g -A _AUTH_USER_POLICIES=() 2>/dev/null || true
declare -g -A _AUTH_POLICIES=() 2>/dev/null || true
declare -g -A _AUTH_REVOKED=() 2>/dev/null || true

# Generate a root token (unlimited capabilities)
auth_create_root_token() {
    local token
    token=$(_crypto_random_hex 32)
    mkdir -p "$_AUTH_TOKENS_DIR"
    printf '%s' "root:root:0" > "${_AUTH_TOKENS_DIR}/${token}"
    echo "$token"
}

# Create a scoped token
auth_create_token() {
    local username="${1:?username required}"
    local policies_csv="${2:-}"
    local token
    token=$(_crypto_random_hex 32)
    mkdir -p "$_AUTH_TOKENS_DIR"
    printf '%s' "$username:$policies_csv:0" > "${_AUTH_TOKENS_DIR}/${token}"
    echo "$token"
}

# Revoke a token synchronously
auth_revoke_token() {
    local body="${1:-}"
    # Body is JSON {"token": "token_to_revoke"}
    local token_to_revoke
    token_to_revoke=$(echo "$body" | jq -r '.token' 2>/dev/null)
    if [[ -z "$token_to_revoke" || "$token_to_revoke" == "null" ]]; then
        http_respond 400 '{"error":"token required"}'
        return
    fi

    mkdir -p "$_AUTH_REVOKED_DIR"
    printf '1' > "${_AUTH_REVOKED_DIR}/${token_to_revoke}"
    rm -f "${_AUTH_TOKENS_DIR}/${token_to_revoke}" 2>/dev/null || true

    # Audit the revocation under the caller token if available
    local caller_token="${_HTTP_TOKEN:-none}"
    audit_append "auth" "$caller_token" "revoke" "auth/revoke" "success"
    http_respond 204 ""
}

# Validate token capabilities on a specific path
auth_validate_token() {
    local token="${1:-}"
    local path="${2:?path required}"
    local capability="${3:?capability required}"

    if [[ -z "$token" ]]; then
        return 1
    fi

    # Synchronous revocation check
    local revoked=0
    if [[ -f "${_AUTH_REVOKED_DIR}/${token}" ]]; then
        revoked=1
    elif declare -p _AUTH_REVOKED 2>/dev/null | grep -q 'declare -A'; then
        if [[ "${_AUTH_REVOKED[$token]:-}" == "1" ]]; then
            revoked=1
        fi
    fi
    if [[ "$revoked" -eq 1 ]]; then
        return 1
    fi

    local info=""
    if [[ -f "${_AUTH_TOKENS_DIR}/${token}" ]]; then
        info=$(cat "${_AUTH_TOKENS_DIR}/${token}")
    elif declare -p _AUTH_TOKENS 2>/dev/null | grep -q 'declare -A'; then
        if [[ -n "${_AUTH_TOKENS[$token]:-}" ]]; then
            info="${_AUTH_TOKENS[$token]}"
        fi
    fi
    if [[ -z "$info" ]]; then
        return 1
    fi

    if [[ -z "$info" ]]; then
        return 1
    fi

    local username="${info%%:*}"
    local rest="${info#*:}"
    local policies_csv="${rest%%:*}"

    # Root policy gets full access
    if [[ ",$policies_csv," == *",root,"* ]]; then
        return 0
    fi

    _auth_policy_allows "$policies_csv" "$path" "$capability"
}

# Internal policy checker: returns 0 if allowed, 1 if forbidden
_auth_policy_allows() {
    local policies_csv="${1:-}"
    local path="${2:?}"
    local capability="${3:?}"

    if [[ -z "$policies_csv" ]]; then
        return 1
    fi

    local IFS=','
    read -ra plist <<< "$policies_csv" || true

    for pol in "${plist[@]}"; do
        [[ -z "$pol" ]] && continue
        local pfile="${_AUTH_POLICIES_DIR}/${pol}"
        local rules_json=""
        if [[ -f "$pfile" ]]; then
            rules_json=$(cat "$pfile")
        elif declare -p _AUTH_POLICIES 2>/dev/null | grep -q 'declare -A'; then
            if [[ -n "${_AUTH_POLICIES[$pol]:-}" ]]; then
                rules_json="${_AUTH_POLICIES[$pol]}"
            fi
        fi
        [[ -z "$rules_json" ]] && continue

        # Match path exactly OR check wildcard path prefix
        local matched
        matched=$(echo "$rules_json" | jq --arg path "$path" --arg cap "$capability" '
            .rules[] | .path as $p |
            select(
                ($path == $p) or
                ($p | endswith("*") and ($path | startswith($p[0:-1])))
            ) | select(.capabilities | contains([$cap]))
        ' 2>/dev/null)

        if [[ -n "$matched" ]]; then
            return 0
        fi
    done

    return 1
}

# User registration endpoint
handle_auth_create_user() {
    local username="${1:?}"
    local token="${2:-}"
    local body="${3:-}"

    # Only root/sys writes can create users
    if ! auth_validate_token "$token" "auth/users" "write"; then
        http_respond 403 '{"error":"forbidden"}'
        return
    fi

    local password
    password=$(echo "$body" | jq -r '.password' 2>/dev/null)
    local policies_json
    policies_json=$(echo "$body" | jq -r '.policies | join(",")' 2>/dev/null)

    if [[ -z "$password" || "$password" == "null" ]]; then
        http_respond 400 '{"error":"password required"}'
        return
    fi

    local hashed_pw
    hashed_pw=$(auth_hash_password "$password")

    mkdir -p "$_AUTH_USERS_DIR" "$_AUTH_USER_POLICIES_DIR"
    printf '%s' "$hashed_pw" > "${_AUTH_USERS_DIR}/${username}"
    printf '%s' "$policies_json" > "${_AUTH_USER_POLICIES_DIR}/${username}"

    audit_append "auth" "$token" "create_user" "auth/users/${username}" "success"
    http_respond 201 '{"status":"user created"}'
}

# Handle user login and issue a scoped token
auth_login() {
    local body="${1:-}"

    local username
    username=$(echo "$body" | jq -r '.username' 2>/dev/null)
    local password
    password=$(echo "$body" | jq -r '.password' 2>/dev/null)

    if [[ -z "$username" || "$username" == "null" || -z "$password" || "$password" == "null" ]]; then
        http_respond 400 '{"error":"username and password required"}'
        return
    fi

    if [[ ! -f "${_AUTH_USERS_DIR}/${username}" ]]; then
        http_respond 401 '{"error":"invalid credentials"}'
        return
    fi

    local stored_hash
    stored_hash=$(cat "${_AUTH_USERS_DIR}/${username}")
    if [[ -z "$stored_hash" ]]; then
        http_respond 401 '{"error":"invalid credentials"}'
        return
    fi

    if ! auth_verify_password "$password" "$stored_hash"; then
        http_respond 401 '{"error":"invalid credentials"}'
        return
    fi

    local policies_csv=""
    if [[ -f "${_AUTH_USER_POLICIES_DIR}/${username}" ]]; then
        policies_csv=$(cat "${_AUTH_USER_POLICIES_DIR}/${username}")
    fi

    local token
    token=$(auth_create_token "$username" "$policies_csv")

    local policies_json="[]"
    if [[ -n "$policies_csv" ]]; then
        policies_json=$(echo "[\"${policies_csv//,/\",\"}\"]")
    fi

    audit_append "auth" "none" "login" "auth/login" "success"
    http_respond 200 "{\"token\":\"${token}\",\"policies\":${policies_json}}"
}

# Hash a password using Argon2id CLI
auth_hash_password() {
    local password="${1:?}"
    local salt
    salt=$(_crypto_random_hex 8)
    local hash
    hash=$(echo -n "$password" | argon2 "$salt" -id -t 3 -m 16 -p 1 -l 32 -e)
    echo "$hash"
}

# Verify password against Argon2id hash
auth_verify_password() {
    local password="${1:?}"
    local hash="${2:?}"

    local salt_b64
    salt_b64=$(echo "$hash" | cut -d'$' -f5)
    local salt
    salt=$(echo "$salt_b64" | base64 -d | xxd -p | tr -d '\n')

    local computed
    computed=$(echo -n "$password" | argon2 "$salt" -id -t 3 -m 16 -p 1 -l 32 -e)

    if [[ "$computed" == "$hash" ]]; then
        return 0
    else
        return 1
    fi
}

# Print token information
auth_token_info() {
    local token="${1:-}"
    if [[ -z "$token" || -f "${_AUTH_REVOKED_DIR}/${token}" || ! -f "${_AUTH_TOKENS_DIR}/${token}" ]]; then
        http_respond 401 '{"error":"unauthorized"}'
        return
    fi

    local info
    info=$(cat "${_AUTH_TOKENS_DIR}/${token}")
    local username="${info%%:*}"
    local rest="${info#*:}"
    local policies_csv="${rest%%:*}"

    local policies_json="[]"
    if [[ -n "$policies_csv" ]]; then
        policies_json=$(echo "[\"${policies_csv//,/\",\"}\"]")
    fi

    http_respond 200 "{\"token_id\":\"${token}\",\"policies\":${policies_json},\"ttl\":3600}"
}

# Handle creating a policy
auth_create_policy() {
    local name="${1:?}"
    local token="${2:-}"
    local body="${3:-}"

    if ! auth_validate_token "$token" "policies" "write"; then
        http_respond 403 '{"error":"forbidden"}'
        return
    fi

    mkdir -p "$_AUTH_POLICIES_DIR"
    printf '%s' "$body" > "${_AUTH_POLICIES_DIR}/${name}"

    audit_append "auth" "$token" "write_policy" "policies/${name}" "success"
    http_respond 201 '{"status":"policy created"}'
}

# Handle reading a policy
auth_get_policy() {
    local name="${1:?}"
    local token="${2:-}"

    if ! auth_validate_token "$token" "policies" "read"; then
        http_respond 403 '{"error":"forbidden"}'
        return
    fi

    if [[ ! -f "${_AUTH_POLICIES_DIR}/${name}" ]]; then
        http_respond 404 '{"error":"policy not found"}'
        return
    fi

    local policy_json
    policy_json=$(cat "${_AUTH_POLICIES_DIR}/${name}")
    http_respond 200 "$policy_json"
}
