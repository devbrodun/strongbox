#!/usr/bin/env bash
# lib/http.sh — HTTP request routing and response helpers
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)

set -euo pipefail

_HTTP_METHOD=""
_HTTP_PATH=""
_HTTP_QUERY=""
_HTTP_BODY=""
_HTTP_TOKEN=""

# Start the sequential netcat-based TCP loop
http_serve() {
    local bind_addr="${1:-0.0.0.0}"
    local port="${2:-8200}"
    local req_fifo="/tmp/strongbox-req-fifo-${STRONGBOX_NODE_ID:-8200}"
    local resp_fifo="/tmp/strongbox-resp-fifo-${STRONGBOX_NODE_ID:-8200}"

    rm -f "$req_fifo" "$resp_fifo"
    mkfifo "$req_fifo" "$resp_fifo"

    echo "[http] listening on $bind_addr:$port..." >&2

    while true; do
        if [[ "$bind_addr" == "0.0.0.0" ]]; then
            nc -l "$port" > "$req_fifo" < "$resp_fifo" &
        else
            nc -l "$bind_addr" "$port" > "$req_fifo" < "$resp_fifo" &
        fi
        local nc_pid=$!

        # Open in non-blocking read-write mode (never fails with EINTR)
        exec 3<>"$req_fifo"
        exec 4<>"$resp_fifo"

        # Process request in parent process context to preserve memory
        _http_handle_conn <&3 >&4 || true

        # Close the FDs: immediately triggers EOF on nc's stdin, letting nc exit cleanly
        exec 3>&-
        exec 4>&-

        wait "$nc_pid" 2>/dev/null || true
    done
}

# Process a single HTTP connection
_http_handle_conn() {
    echo "[http] Accepted connection" >&2
    if [[ "$(type -t consensus_load_state)" == "function" ]]; then
        consensus_load_state || true
    fi
    if ! http_parse_request; then
        echo "[http] Failed to parse request" >&2
        return
    fi
    echo "[http] Request: $_HTTP_METHOD $_HTTP_PATH" >&2
    _http_route
}

# Parse raw HTTP request from stdin
http_parse_request() {
    _HTTP_METHOD=""
    _HTTP_PATH=""
    _HTTP_QUERY=""
    _HTTP_BODY=""
    _HTTP_TOKEN=""

    local req_line
    if ! IFS= read -r req_line; then
        return 1
    fi
    # Strip carriage return
    req_line="${req_line%$'\r'}"

    # Extract method, full path, and HTTP protocol version
    local method path_full proto
    read -r method path_full proto <<< "$req_line" || true

    _HTTP_METHOD="$method"

    # Separate path and query parameters
    if [[ "$path_full" == *"?"* ]]; then
        _HTTP_PATH="${path_full%%\?*}"
        _HTTP_QUERY="${path_full#*\?}"
    else
        _HTTP_PATH="$path_full"
        _HTTP_QUERY=""
    fi

    # Read headers line by line
    local content_length=0
    local line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && break

        local h_name="${line%%:*}"
        local h_val="${line#*:}"
        h_name=$(echo "$h_name" | xargs | tr '[:upper:]' '[:lower:]')
        h_val=$(echo "$h_val" | xargs)

        if [[ "$h_name" == "content-length" ]]; then
            content_length="$h_val"
        elif [[ "$h_name" == "authorization" ]]; then
            if [[ "$h_val" == "Bearer "* ]]; then
                _HTTP_TOKEN="${h_val#Bearer }"
            fi
        fi
    done

    # Read exactly content_length bytes for the request body
    if [[ "$content_length" -gt 0 ]]; then
        _HTTP_BODY=$(head -c "$content_length"; echo x)
        _HTTP_BODY="${_HTTP_BODY%x}"
    fi

    return 0
}

# Format and write an HTTP response to stdout
http_respond() {
    local status_code="${1:?status code required}"
    local body="${2:-}"
    local location="${3:-}"
    local status_text="OK"

    case "$status_code" in
        200) status_text="OK" ;;
        201) status_text="Created" ;;
        204) status_text="No Content" ;;
        307) status_text="Temporary Redirect" ;;
        400) status_text="Bad Request" ;;
        401) status_text="Unauthorized" ;;
        403) status_text="Forbidden" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        500) status_text="Internal Server Error" ;;
        503) status_text="Service Unavailable" ;;
    esac

    local content_len=${#body}
    printf "HTTP/1.1 %d %s\r\n" "$status_code" "$status_text"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "$content_len"
    printf "Connection: close\r\n"
    if [[ -n "$location" ]]; then
        printf "Location: %s\r\n" "$location"
    fi
    printf "\r\n"
    if [[ "$content_len" -gt 0 ]]; then
        printf "%s" "$body"
    fi

    # State-dirty optimization tracking
    if [[ "${_CONSENSUS_ROLE:-}" == "leader" ]] && [[ "$status_code" =~ ^(200|201|204)$ ]] && [[ "${_HTTP_METHOD:-}" =~ ^(POST|PUT|DELETE)$ ]] && [[ "${_HTTP_PATH:-}" != "/v1/sys/health" && "${_HTTP_PATH:-}" != "/v1/internal/"* ]]; then
        touch "/tmp/strongbox-state-dirty-${STRONGBOX_NODE_ID:-8200}"
    fi
}

# Dispatch the parsed request to the correct handler
_http_route() {
    local method="$_HTTP_METHOD"
    local path="$_HTTP_PATH"
    local body="$_HTTP_BODY"
    local token="$_HTTP_TOKEN"

    # 1. Sealed vault protection
    if [[ "$STRONGBOX_SEALED" == "true" ]]; then
        if [[ "$path" != "/v1/sys/health" && "$path" != "/v1/sys/unseal" && "$path" != "/v1/sys/init" ]]; then
            http_respond 503 '{"error":"vault is sealed"}'
            return
        fi
    fi

    # 2. Standard exact matching routes
    if [[ "$method" == "POST" && "$path" == "/v1/sys/init" ]]; then
        handle_sys_init
    elif [[ "$method" == "POST" && "$path" == "/v1/sys/unseal" ]]; then
        handle_sys_unseal "$body"
    elif [[ "$method" == "POST" && "$path" == "/v1/sys/seal" ]]; then
        handle_sys_seal "$token"
    elif [[ "$method" == "GET" && "$path" == "/v1/sys/health" ]]; then
        handle_sys_health
    elif [[ "$method" == "POST" && "$path" == "/v1/auth/login" ]]; then
        handle_auth_login "$body"
    elif [[ "$method" == "POST" && "$path" == "/v1/auth/revoke" ]]; then
        handle_auth_revoke "$body"
    elif [[ "$method" == "GET" && "$path" == "/v1/auth/self" ]]; then
        handle_auth_self "$token"
    elif [[ "$method" == "GET" && "$path" == "/v1/audit" ]]; then
        local query_token
        query_token=$(_http_extract_query_param "token")
        handle_audit_query "$query_token"
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/vote" ]]; then
        consensus_handle_vote_request "$body"
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/heartbeat" ]]; then
        consensus_handle_heartbeat "$body"
    elif [[ "$method" == "GET" && "$path" == "/v1/internal/state" ]]; then
        consensus_handle_get_state
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/start-election" ]]; then
        consensus_handle_start_election
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/become-leader" ]]; then
        consensus_handle_become_leader "$body"
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/step-down" ]]; then
        consensus_handle_step_down
    elif [[ "$method" == "POST" && "$path" == "/v1/internal/reap" ]]; then
        handle_lease_reap

    # 3. Prefix-matching routes
    elif [[ "$path" == "/v1/secrets/"* ]]; then
        local secret_path="${path#/v1/secrets/}"
        if [[ -z "$secret_path" ]]; then
            http_respond 400 '{"error":"missing secret path"}'
        elif [[ "$method" == "PUT" ]]; then
            handle_secret_write "$secret_path" "$token" "$body"
        elif [[ "$method" == "GET" ]]; then
            local version_param
            version_param=$(_http_extract_query_param "version")
            handle_secret_read "$secret_path" "$token" "$version_param"
        elif [[ "$method" == "DELETE" ]]; then
            handle_secret_delete "$secret_path" "$token"
        else
            http_respond 405 '{"error":"method not allowed"}'
        fi

    elif [[ "$path" == "/v1/dynamic-postgres/"* ]]; then
        local role="${path#/v1/dynamic-postgres/}"
        if [[ -z "$role" ]]; then
            http_respond 400 '{"error":"missing role name"}'
        elif [[ "$method" == "GET" ]]; then
            handle_dynamic_postgres_read "$role" "$token"
        else
            http_respond 405 '{"error":"method not allowed"}'
        fi

    elif [[ "$path" == "/v1/policies/"* ]]; then
        local policy_name="${path#/v1/policies/}"
        if [[ -z "$policy_name" ]]; then
            http_respond 400 '{"error":"missing policy name"}'
        elif [[ "$method" == "PUT" ]]; then
            handle_policy_write "$policy_name" "$token" "$body"
        elif [[ "$method" == "GET" ]]; then
            handle_policy_read "$policy_name" "$token"
        else
            http_respond 405 '{"error":"method not allowed"}'
        fi

    elif [[ "$path" == "/v1/leases/"* ]]; then
        local suffix="${path#/v1/leases/}"
        local lease_id="${suffix%%/*}"
        local op="${suffix##*/}"

        if [[ -z "$lease_id" || -z "$op" ]]; then
            http_respond 400 '{"error":"invalid lease path"}'
        elif [[ "$method" == "POST" && "$op" == "renew" ]]; then
            handle_lease_renew "$lease_id" "$body"
        elif [[ "$method" == "POST" && "$op" == "revoke" ]]; then
            handle_lease_revoke "$lease_id"
        else
            http_respond 405 '{"error":"method not allowed"}'
        fi

    elif [[ "$method" == "POST" && "$path" == "/v1/auth/users/"* ]]; then
        local username="${path#/v1/auth/users/}"
        if [[ -z "$username" ]]; then
            http_respond 400 '{"error":"missing username"}'
        else
            handle_auth_create_user "$username" "$token" "$body"
        fi

    else
        http_respond 404 '{"error":"route not found"}'
    fi
}

# Helper to extract query parameters from query string
_http_extract_query_param() {
    local key="${1:?}"
    local query="$_HTTP_QUERY"
    if [[ "$query" =~ (^|&)"$key"=([^&]*) ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo ""
    fi
}
