#!/usr/bin/env bash
# lib/consensus.sh — Hand-rolled leader election (Raft-inspired)
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)

set -euo pipefail

_CONSENSUS_ROLE="follower"      # follower | candidate | leader
_CONSENSUS_TERM=0
_CONSENSUS_LEADER=""
_CONSENSUS_VOTED_FOR=""
_CONSENSUS_VOTES=0

STRONGBOX_PEERS="${STRONGBOX_PEERS:-}"   # comma-separated "host:port,host:port"
STRONGBOX_NODE_ADDR="${STRONGBOX_NODE_ADDR:-localhost:8200}"

STRONGBOX_DATA_DIR="${STRONGBOX_DATA_DIR:-/var/lib/strongbox}"
_STORAGE_DIR="${STRONGBOX_DATA_DIR}/store"

# Get portable timestamp in milliseconds
_get_time_ms() {
    local t=""
    if [[ "${OSTYPE:-}" == "darwin"* ]]; then
        t=$(python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null) || t=""
    fi
    if [[ -z "$t" ]]; then
        t=$(date +%s%3N 2>/dev/null) || t=""
    fi
    if [[ -z "$t" ]]; then
        t=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
    fi
    echo "${t:-0}"
}

_consensus_quorum() {
    local count=1 # us
    local IFS=','
    read -ra peer_list <<< "${STRONGBOX_PEERS:-}"
    for peer in "${peer_list[@]}"; do
        [[ -n "$peer" ]] && count=$(( count + 1 ))
    done
    echo $(( (count / 2) + 1 ))
}

_consensus_touch_heartbeat() {
    local hb_file="/tmp/strongbox-last-heartbeat-${STRONGBOX_NODE_ID:-8200}"
    _get_time_ms > "$hb_file"
}

# Helper to recursively serialize a directory's files into a compact JSON object (base64 encoded content)
_serialize_dir_to_json() {
    local dir="${1:?}"
    [[ ! -d "$dir" ]] && echo "{}" && return

    python3 -c "
import sys, os, base64, json
dir_path = sys.argv[1]
res = {}
if os.path.isdir(dir_path):
    for root, dirs, files in os.walk(dir_path):
        for file in files:
            full_path = os.path.join(root, file)
            rel_path = os.path.relpath(full_path, dir_path)
            try:
                with open(full_path, 'rb') as f:
                    res[rel_path] = base64.b64encode(f.read()).decode('utf-8')
            except Exception:
                pass
print(json.dumps(res))
" "$dir" 2>/dev/null || echo "{}"
}

# Helper to deserialize a JSON object (base64 encoded content) into a directory
_deserialize_json_to_dir() {
    local json="${1:?}"
    local dir="${2:?}"

    rm -rf "$dir"
    mkdir -p "$dir"

    echo "$json" | python3 -c "
import sys, json, os, base64
dir_path = sys.argv[1]
data = json.loads(sys.stdin.read())
for rel_path, b64_content in data.items():
    full_path = os.path.join(dir_path, rel_path.lstrip('./'))
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, 'wb') as f:
        f.write(base64.b64decode(b64_content))
" "$dir" 2>/dev/null || true
}

# Serialize all storage, auth, policies, and leases directories into a single compact JSON string
_consensus_serialize_state() {
    local store_json; store_json=$(_serialize_dir_to_json "$_STORAGE_DIR")
    local auth_json; auth_json=$(_serialize_dir_to_json "${STRONGBOX_DATA_DIR}/auth")
    local policies_json; policies_json=$(_serialize_dir_to_json "${STRONGBOX_DATA_DIR}/policies")
    local leases_json; leases_json=$(_serialize_dir_to_json "${STRONGBOX_DATA_DIR}/leases")

    jq -c -n \
        --argjson store "$store_json" \
        --argjson auth "$auth_json" \
        --argjson policies "$policies_json" \
        --argjson leases "$leases_json" \
        '{store: $store, auth: $auth, policies: $policies, leases: $leases}'
}

# Deserialize state payload directly into corresponding state folders on disk
_consensus_deserialize_state() {
    local state_json="${1:?}"

    local store_data; store_data=$(echo "$state_json" | jq -c '.store' 2>/dev/null || echo "{}")
    local auth_data; auth_data=$(echo "$state_json" | jq -c '.auth' 2>/dev/null || echo "{}")
    local policies_data; policies_data=$(echo "$state_json" | jq -c '.policies' 2>/dev/null || echo "{}")
    local leases_data; leases_data=$(echo "$state_json" | jq -c '.leases' 2>/dev/null || echo "{}")

    _deserialize_json_to_dir "$store_data" "$_STORAGE_DIR"
    _deserialize_json_to_dir "$auth_data" "${STRONGBOX_DATA_DIR}/auth"
    _deserialize_json_to_dir "$policies_data" "${STRONGBOX_DATA_DIR}/policies"
    _deserialize_json_to_dir "$leases_data" "${STRONGBOX_DATA_DIR}/leases"
}

_consensus_save_state_to_file() {
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    local tmp_file="${state_file}.$$.${RANDOM}"
    printf "role=%s\nterm=%d\nleader=%s\nvoted_for=%s\nsealed=%s\n" \
        "$_CONSENSUS_ROLE" "$_CONSENSUS_TERM" "$_CONSENSUS_LEADER" "$_CONSENSUS_VOTED_FOR" "$STRONGBOX_SEALED" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"
}

consensus_load_state() {
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            case "$key" in
                role) _CONSENSUS_ROLE="$val" ;;
                term) _CONSENSUS_TERM="$val" ;;
                leader) _CONSENSUS_LEADER="$val" ;;
                voted_for) _CONSENSUS_VOTED_FOR="$val" ;;
                sealed) STRONGBOX_SEALED="$val" ;;
            esac
        done < "$state_file"
    fi
}

_consensus_get_state_version() {
    local version_file="/tmp/strongbox-state-version-${STRONGBOX_NODE_ID:-8200}"
    if [[ -f "$version_file" ]]; then
        local ver
        read -r ver < "$version_file"
        echo "${ver:-0}"
    else
        echo "0"
    fi
}

_consensus_set_state_version() {
    local ver="${1:?}"
    local version_file="/tmp/strongbox-state-version-${STRONGBOX_NODE_ID:-8200}"
    local tmp_file="${version_file}.$$.${RANDOM}"
    echo "$ver" > "$tmp_file"
    mv -f "$tmp_file" "$version_file"
}

# Start election timer and heartbeat broadcasting subshells
consensus_start() {
    _consensus_save_state_to_file
    _consensus_election_loop &
    _consensus_heartbeat_loop &
}

consensus_is_leader() {
    [[ "$_CONSENSUS_ROLE" == "leader" ]]
}

consensus_leader_addr() {
    echo "$_CONSENSUS_LEADER"
}

consensus_current_term() {
    echo "$_CONSENSUS_TERM"
}

# Synchronously serializes and broadcasts the state
consensus_sync_state() {
    if [[ "$_CONSENSUS_ROLE" == "leader" ]]; then
        _consensus_broadcast_state_async &
    fi
}

_consensus_broadcast_state_async() {
    consensus_load_state || true
    local term="$_CONSENSUS_TERM"
    local state_json
    state_json=$(_consensus_serialize_state)
    local ver
    ver=$(_consensus_get_state_version)

    local IFS=','
    read -ra peer_list <<< "${STRONGBOX_PEERS:-}"
    for peer in "${peer_list[@]}"; do
        [[ -z "$peer" ]] && continue
        curl -s -m 0.15 -X POST "http://$peer/v1/internal/heartbeat" \
            -H "Content-Type: application/json" \
            -d "{\"term\":$term,\"leader\":\"$STRONGBOX_NODE_ADDR\",\"state_version\":$ver,\"state\":$state_json}" >/dev/null 2>&1 || true
    done
}

_consensus_start_election_direct() {
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    local role="follower" term=0 leader="" voted_for="" sealed="true"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            case "$key" in
                role) role="$val" ;;
                term) term="$val" ;;
                leader) leader="$val" ;;
                voted_for) voted_for="$val" ;;
                sealed) sealed="$val" ;;
            esac
        done < "$state_file"
    fi

    role="candidate"
    term=$(( term + 1 ))
    voted_for="$STRONGBOX_NODE_ADDR"
    leader=""

    local tmp_file="${state_file}.$$.${RANDOM}"
    printf "role=%s\nterm=%d\nleader=%s\nvoted_for=%s\nsealed=%s\n" \
        "$role" "$term" "$leader" "$voted_for" "$sealed" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"

    _consensus_touch_heartbeat

    echo "term=$term role=$role"
}

_consensus_become_leader_direct() {
    local term="${1:?}"
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    local role="follower" lterm=0 leader="" voted_for="" sealed="true"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            case "$key" in
                role) role="$val" ;;
                term) lterm="$val" ;;
                leader) leader="$val" ;;
                voted_for) voted_for="$val" ;;
                sealed) sealed="$val" ;;
            esac
        done < "$state_file"
    fi

    if [[ "$term" -eq "$lterm" && "$role" == "candidate" ]]; then
        role="leader"
        leader="$STRONGBOX_NODE_ADDR"
        : > "/tmp/strongbox-state-dirty-${STRONGBOX_NODE_ID:-8200}"

        local tmp_file="${state_file}.$$.${RANDOM}"
        printf "role=%s\nterm=%d\nleader=%s\nvoted_for=%s\nsealed=%s\n" \
            "$role" "$lterm" "$leader" "$voted_for" "$sealed" > "$tmp_file"
        mv -f "$tmp_file" "$state_file"

        echo "[consensus] became leader for term $lterm" >&2
        
        # Broadcast state directly in background
        _consensus_broadcast_state_async &
        echo '{"success":true}'
    else
        echo "{\"success\":false,\"error\":\"term mismatch (term=$term, local_term=$lterm) or not candidate (role=$role)\"}"
    fi
}

_consensus_step_down_direct() {
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    local role="follower" term=0 leader="" voted_for="" sealed="true"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            case "$key" in
                role) role="$val" ;;
                term) term="$val" ;;
                leader) leader="$val" ;;
                voted_for) voted_for="$val" ;;
                sealed) sealed="$val" ;;
            esac
        done < "$state_file"
    fi

    role="follower"
    leader=""
    voted_for=""

    local tmp_file="${state_file}.$$.${RANDOM}"
    printf "role=%s\nterm=%d\nleader=%s\nvoted_for=%s\nsealed=%s\n" \
        "$role" "$term" "$leader" "$voted_for" "$sealed" > "$tmp_file"
    mv -f "$tmp_file" "$state_file"
}

# Background election timeout loop
_consensus_election_loop() {
    sleep 2
    local hb_file="/tmp/strongbox-last-heartbeat-${STRONGBOX_NODE_ID:-8200}"
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"
    _consensus_touch_heartbeat

    while true; do
        local sealed="true"
        local current_role="follower"
        if [[ -f "$state_file" ]]; then
            # Read state_file line-by-line using pure Bash (no fork!)
            while IFS='=' read -r key val || [[ -n "$key" ]]; do
                case "$key" in
                    sealed) sealed="$val" ;;
                    role) current_role="$val" ;;
                esac
            done < "$state_file"
        fi

        if [[ "$sealed" == "true" ]]; then
            sleep 0.1
            continue
        fi

        if [[ "$current_role" == "leader" ]]; then
            sleep 0.1
            continue
        fi

        # Generate randomized timeout in ms: 500ms to 900ms
        local r=$(( RANDOM % 401 ))
        local timeout_ms=$(( 500 + r ))
        local sleep_sec="0.${timeout_ms}"
        sleep "$sleep_sec"

        # Read last heartbeat timestamp AFTER sleep to catch any updates received during sleep
        local last_hb=0
        if [[ -f "$hb_file" ]]; then
            read -r last_hb < "$hb_file" || last_hb=0
        fi

        # Check if heartbeat has been touched during sleep
        local now
        now=$(_get_time_ms)
        local elapsed=$(( now - last_hb ))

        if [[ "$elapsed" -lt "$timeout_ms" ]]; then
            continue
        fi

        echo "[consensus] timeout elapsed (elapsed=$elapsed ms, timeout=$timeout_ms ms), starting election..." >&2

        local start_out
        start_out=$(_consensus_start_election_direct)
        local candidate_term="${start_out%% *}"
        candidate_term="${candidate_term#term=}"
        local candidate_role="${start_out##* }"
        candidate_role="${candidate_role#role=}"

        echo "[consensus] started election locally: term=$candidate_term role=$candidate_role" >&2

        if [[ "$candidate_role" == "candidate" ]]; then
            local votes=1
            local quorum
            quorum=$(_consensus_quorum)

            local IFS=','
            read -ra peer_list <<< "${STRONGBOX_PEERS:-}"
            for peer in "${peer_list[@]}"; do
                [[ -z "$peer" ]] && continue
                local vote_resp
                vote_resp=$(curl -s -m 0.25 -X POST "http://$peer/v1/internal/vote" \
                    -H "Content-Type: application/json" \
                    -d "{\"term\":$candidate_term,\"candidate\":\"$STRONGBOX_NODE_ADDR\"}" 2>/dev/null) || {
                    echo "[consensus] failed to get vote response from peer $peer" >&2
                    continue
                }
                
                local granted
                granted=$(echo "$vote_resp" | jq -r '.vote_granted' 2>/dev/null)
                echo "[consensus] peer $peer responded to vote request: granted=$granted, response=$vote_resp" >&2
                if [[ "$granted" == "true" ]]; then
                    votes=$(( votes + 1 ))
                fi
            done

            echo "[consensus] election finished: term=$candidate_term votes=$votes/$quorum" >&2

            if [[ "$votes" -ge "$quorum" ]]; then
                echo "[consensus] quorum reached, attempting to become leader..." >&2
                local become_resp
                become_resp=$(_consensus_become_leader_direct "$candidate_term")
                echo "[consensus] become-leader response: $become_resp" >&2
            fi
        fi
    done
}

# Background leader heartbeat loop
_consensus_heartbeat_loop() {
    sleep 2
    local state_file="/tmp/strongbox-state-${STRONGBOX_NODE_ID:-8200}"

    while true; do
        local sealed="true"
        local role="follower"
        local term=0
        if [[ -f "$state_file" ]]; then
            # Read state_file line-by-line using pure Bash (no fork!)
            while IFS='=' read -r key val || [[ -n "$key" ]]; do
                case "$key" in
                    sealed) sealed="$val" ;;
                    role) role="$val" ;;
                    term) term="$val" ;;
                esac
            done < "$state_file"
        fi

        if [[ "$sealed" == "true" ]]; then
            sleep 0.1
            continue
        fi

        if [[ "$role" == "leader" ]]; then
            local state_json="null"
            local dirty_file="/tmp/strongbox-state-dirty-${STRONGBOX_NODE_ID:-8200}"
            if [[ -f "$dirty_file" ]]; then
                state_json=$(_consensus_serialize_state)
                rm -f "$dirty_file"
            fi

            local ver
            ver=$(_consensus_get_state_version)

            local active_nodes=1
            local quorum
            quorum=$(_consensus_quorum)

            local IFS=','
            read -ra peer_list <<< "${STRONGBOX_PEERS:-}"
            for peer in "${peer_list[@]}"; do
                [[ -z "$peer" ]] && continue
                local hb_resp
                hb_resp=$(curl -s -m 0.25 -X POST "http://$peer/v1/internal/heartbeat" \
                    -H "Content-Type: application/json" \
                    -d "{\"term\":$term,\"leader\":\"$STRONGBOX_NODE_ADDR\",\"state_version\":$ver,\"state\":$state_json}" 2>/dev/null) || continue
                
                # If a follower is out of sync, touch dirty file to trigger state replication on the next pulse
                local needs_sync
                needs_sync=$(echo "$hb_resp" | jq -r '.needs_sync' 2>/dev/null)
                if [[ "$needs_sync" == "true" ]]; then
                    : > "$dirty_file"
                fi

                active_nodes=$(( active_nodes + 1 ))
            done

            if [[ "$active_nodes" -lt "$quorum" ]]; then
                echo "[consensus] minority partition ($active_nodes < $quorum), stepping down..." >&2
                _consensus_step_down_direct
            fi
        fi

        sleep 0.15
    done
}

# ---------------------------------------------------------------------------
# HTTP Route Handlers for Consensus (run inside main process context)
# ---------------------------------------------------------------------------

consensus_handle_get_state() {
    local state_payload
    state_payload=$(_consensus_serialize_state)
    http_respond 200 "{\"role\":\"$_CONSENSUS_ROLE\",\"term\":$_CONSENSUS_TERM\",\"leader\":\"$_CONSENSUS_LEADER\",\"voted_for\":\"$_CONSENSUS_VOTED_FOR\",\"state\":$state_payload}"
}

consensus_handle_start_election() {
    _CONSENSUS_ROLE="candidate"
    _CONSENSUS_TERM=$(( _CONSENSUS_TERM + 1 ))
    _CONSENSUS_VOTED_FOR="$STRONGBOX_NODE_ADDR"
    _consensus_touch_heartbeat
    _consensus_save_state_to_file
    http_respond 200 "{\"role\":\"$_CONSENSUS_ROLE\",\"term\":$_CONSENSUS_TERM}"
}

consensus_handle_become_leader() {
    local body="${1:-}"
    local term
    term=$(echo "$body" | jq -r '.term' 2>/dev/null)

    if [[ "$term" -eq "$_CONSENSUS_TERM" && "$_CONSENSUS_ROLE" == "candidate" ]]; then
        _CONSENSUS_ROLE="leader"
        _CONSENSUS_LEADER="$STRONGBOX_NODE_ADDR"
        : > "/tmp/strongbox-state-dirty-${STRONGBOX_NODE_ID:-8200}"
        _consensus_save_state_to_file
        echo "[consensus] became leader for term $_CONSENSUS_TERM" >&2
        consensus_sync_state || true
        http_respond 200 '{"success":true}'
    else
        http_respond 200 '{"success":false,"error":"term mismatch or not candidate"}'
    fi
}

consensus_handle_step_down() {
    _CONSENSUS_ROLE="follower"
    _CONSENSUS_LEADER=""
    _CONSENSUS_VOTED_FOR=""
    _consensus_save_state_to_file
    http_respond 200 '{"success":true}'
}

consensus_handle_vote_request() {
    # Load freshest state from disk to prevent race conditions with background election loop
    consensus_load_state || true

    local body="${1:-}"
    local term candidate
    term=$(echo "$body" | jq -r '.term' 2>/dev/null)
    candidate=$(echo "$body" | jq -r '.candidate' 2>/dev/null)

    echo "[consensus] received vote request from candidate=$candidate term=$term (local term=$_CONSENSUS_TERM, voted_for=$_CONSENSUS_VOTED_FOR)" >&2

    if [[ "$term" -gt "$_CONSENSUS_TERM" ]]; then
        echo "[consensus] term $term > local term $_CONSENSUS_TERM, stepping down and updating term" >&2
        _CONSENSUS_TERM="$term"
        _CONSENSUS_ROLE="follower"
        _CONSENSUS_VOTED_FOR=""
        _CONSENSUS_LEADER=""
    fi

    if [[ "$term" -eq "$_CONSENSUS_TERM" && ( -z "$_CONSENSUS_VOTED_FOR" || "$_CONSENSUS_VOTED_FOR" == "$candidate" ) ]]; then
        _CONSENSUS_VOTED_FOR="$candidate"
        _consensus_save_state_to_file
        echo "[consensus] granting vote to $candidate for term $_CONSENSUS_TERM" >&2
        http_respond 200 "{\"vote_granted\":true,\"term\":$_CONSENSUS_TERM}"
    else
        _consensus_save_state_to_file
        echo "[consensus] denying vote to $candidate for term $_CONSENSUS_TERM (already voted for $_CONSENSUS_VOTED_FOR)" >&2
        http_respond 200 "{\"vote_granted\":false,\"term\":$_CONSENSUS_TERM}"
    fi
}

consensus_handle_heartbeat() {
    # Load freshest state from disk to prevent race conditions with background election loop
    consensus_load_state || true

    local body="${1:-}"
    local term leader state_payload state_version
    term=$(echo "$body" | jq -r '.term' 2>/dev/null)
    leader=$(echo "$body" | jq -r '.leader' 2>/dev/null)
    state_version=$(echo "$body" | jq -r '.state_version' 2>/dev/null)
    state_payload=$(echo "$body" | jq -c '.state' 2>/dev/null)

    if [[ "$term" -ge "$_CONSENSUS_TERM" ]]; then
        if [[ "$term" -gt "$_CONSENSUS_TERM" ]]; then
            _CONSENSUS_TERM="$term"
        fi
        _CONSENSUS_ROLE="follower"
        _CONSENSUS_LEADER="$leader"
        _consensus_touch_heartbeat

        local local_ver
        local_ver=$(_consensus_get_state_version)

        local needs_sync="false"
        if [[ -n "$state_version" && "$state_version" != "null" && "$state_version" != "$local_ver" ]]; then
            if [[ -n "$state_payload" && "$state_payload" != "null" ]]; then
                # Only deserialize when we actually receive a non-null payload
                _consensus_deserialize_state "$state_payload"
                _consensus_set_state_version "$state_version"
            else
                needs_sync="true"
            fi
        fi

        _consensus_save_state_to_file
        http_respond 200 "{\"success\":true,\"term\":$_CONSENSUS_TERM,\"needs_sync\":$needs_sync}"
    else
        _consensus_save_state_to_file
        http_respond 200 "{\"success\":false,\"term\":$_CONSENSUS_TERM}"
    fi
}
