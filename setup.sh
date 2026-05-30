#!/usr/bin/env bash
# =============================================================================
# StrongBox — Project Skeleton Setup Script
# Run once on a fresh clone: bash setup.sh
# Creates all folders and stub files so each person can work independently.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo ""
echo "  StrongBox skeleton setup"
echo "  ========================"
echo ""

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
mkdir -p \
  bin \
  lib \
  nginx \
  docs \
  screenshots \
  test/integration \
  data

echo "  [ok] directories created"

# ---------------------------------------------------------------------------
# lib/shamir.py  — PERSON 1
# ---------------------------------------------------------------------------
cat > lib/shamir.py << 'PY'
#!/usr/bin/env python3
"""
lib/shamir.py — Shamir Secret Sharing over GF(2^8)
OWNER: Person 1 (Crypto, Storage & Seal/Unseal)

CLI:
  python3 lib/shamir.py split   <secret_hex> <k> <n>
  python3 lib/shamir.py combine <k> <idx:hex> [<idx:hex> ...]

Implement Lagrange interpolation in GF(2^8).
Irreducible polynomial: x^8 + x^4 + x^3 + x^2 + 1  (0x11d)
NO external libraries. Pure Python math only.
"""
import sys

# TODO: implement GF(2^8) multiply, inverse, poly_eval, lagrange_interpolate
# TODO: implement split_secret(secret_bytes, k, n) -> list[(index, bytes)]
# TODO: implement combine_shares(shares, secret_len) -> bytes
# TODO: implement CLI: split / combine subcommands
# TODO: zero local key material before returning

def main():
    raise NotImplementedError("shamir.py not yet implemented")

if __name__ == "__main__":
    main()
PY
chmod +x lib/shamir.py

# ---------------------------------------------------------------------------
# lib/crypto.sh  — PERSON 1
# ---------------------------------------------------------------------------
cat > lib/crypto.sh << 'SH'
#!/usr/bin/env bash
# lib/crypto.sh — Envelope encryption
# OWNER: Person 1 (Crypto, Storage & Seal/Unseal)
#
# Public API (called by bin/strongbox and other modules):
#   crypto_generate_kek            -> prints 32-byte hex KEK
#   crypto_load_kek   <kek_hex>    -> exports STRONGBOX_KEK; zeros arg
#   crypto_unload_kek              -> zeros and unsets STRONGBOX_KEK
#   crypto_encrypt_secret <plain>  -> prints wrapped_dek_b64|enc_val_b64
#   crypto_decrypt_secret <blob>   -> prints plaintext
#
# Rules:
#   - AES-256-GCM via `openssl enc`
#   - Random 96-bit nonce per encryption from /dev/urandom
#   - DEK wrapped by KEK (envelope encryption)
#   - KEK never written to disk; never logged
#   - Zero all local key copies before returning

set -euo pipefail

# TODO: implement _crypto_random_hex <n_bytes>
# TODO: implement _crypto_aes_gcm_encrypt <key_hex> <nonce_hex> <plaintext_hex>
# TODO: implement _crypto_aes_gcm_decrypt <key_hex> <nonce_hex> <tag_hex> <ct_hex>
# TODO: implement crypto_generate_kek
# TODO: implement crypto_load_kek
# TODO: implement crypto_unload_kek
# TODO: implement crypto_encrypt_secret
# TODO: implement crypto_decrypt_secret

crypto_generate_kek()    { echo "NOT_IMPLEMENTED" >&2; return 1; }
crypto_load_kek()        { echo "NOT_IMPLEMENTED" >&2; return 1; }
crypto_unload_kek()      { echo "NOT_IMPLEMENTED" >&2; return 1; }
crypto_encrypt_secret()  { echo "NOT_IMPLEMENTED" >&2; return 1; }
crypto_decrypt_secret()  { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/storage.sh  — PERSON 1
# ---------------------------------------------------------------------------
cat > lib/storage.sh << 'SH'
#!/usr/bin/env bash
# lib/storage.sh — In-memory storage backend
# OWNER: Person 1 (Crypto, Storage & Seal/Unseal)
#
# Public interface (keep this clean — next team swaps in BoltDB here):
#   storage_put    <path> <blob>      -> prints version (integer)
#   storage_get    <path> [version]   -> prints blob; exit 1 if missing/deleted
#   storage_delete <path>             -> exit 0; exit 1 if not found
#   storage_list   <prefix>           -> newline-separated active paths, sorted
#   storage_latest_version <path>     -> prints integer; exit 1 if not found
#   storage_exists <path>             -> exit 0 if exists and not deleted
#
# Versioning: every PUT increments version. Versions are 1-based.
# GET without version returns latest. GET ?version=N returns that version.
# DELETE marks deleted; history preserved for audit.
# Implementation: bash associative arrays (process-lifetime, no disk).

set -euo pipefail

declare -gA _STORE_VERSIONS=()
declare -gA _STORE_DATA=()
declare -gA _STORE_DELETED=()

# TODO: implement storage_put
# TODO: implement storage_get
# TODO: implement storage_delete
# TODO: implement storage_list
# TODO: implement storage_latest_version
# TODO: implement storage_exists
# TODO: implement _storage_validate_path (reject ".." traversal)

storage_put()            { echo "NOT_IMPLEMENTED" >&2; return 1; }
storage_get()            { echo "NOT_IMPLEMENTED" >&2; return 1; }
storage_delete()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
storage_list()           { echo "NOT_IMPLEMENTED" >&2; return 1; }
storage_latest_version() { echo "NOT_IMPLEMENTED" >&2; return 1; }
storage_exists()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/auth.sh  — PERSON 2
# ---------------------------------------------------------------------------
cat > lib/auth.sh << 'SH'
#!/usr/bin/env bash
# lib/auth.sh — Token auth, Argon2id passwords, policy engine
# OWNER: Person 2 (Auth, Policies & Audit)
#
# Public API:
#   auth_create_root_token                          -> prints token string
#   auth_create_token <username> <policies_csv>     -> prints token string
#   auth_validate_token <token> <path> <capability> -> exit 0 if allowed
#   auth_revoke_token <token>                       -> exit 0
#   auth_login <username> <password>                -> prints token; exit 1 if bad creds
#   auth_hash_password <password>                   -> prints argon2id hash
#   auth_verify_password <password> <hash>          -> exit 0 if match
#   auth_token_info <token>                         -> prints JSON {token_id,policies,ttl}
#   auth_create_policy <name> <rules_json>          -> exit 0
#   auth_get_policy <name>                          -> prints rules JSON
#
# Rules:
#   - Tokens: opaque, >= 32 bytes from /dev/urandom, NOT JWTs
#   - Revocation is synchronous — revoked token fails on next request (no TTL grace)
#   - Token state is server-side only
#   - Passwords hashed with argon2id CLI; never stored plaintext; never logged
#   - Policy: path prefix + capability set {read, write, delete}

set -euo pipefail

declare -gA _AUTH_TOKENS=()       # token -> "username:policies_csv:expires_at"
declare -gA _AUTH_USERS=()        # username -> argon2id_hash
declare -gA _AUTH_POLICIES=()     # name -> rules_json
declare -gA _AUTH_REVOKED=()      # token -> "1"

# TODO: implement auth_create_root_token
# TODO: implement auth_create_token
# TODO: implement auth_validate_token  (check revoked first, then policy match)
# TODO: implement auth_revoke_token
# TODO: implement auth_login
# TODO: implement auth_hash_password   (argon2 CLI: -id -t 3 -m 16 -p 1)
# TODO: implement auth_verify_password
# TODO: implement auth_token_info
# TODO: implement auth_create_policy
# TODO: implement auth_get_policy
# TODO: implement _auth_policy_allows <policies_csv> <path> <capability>

auth_create_root_token()  { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_create_token()       { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_validate_token()     { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_revoke_token()       { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_login()              { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_hash_password()      { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_verify_password()    { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_token_info()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_create_policy()      { echo "NOT_IMPLEMENTED" >&2; return 1; }
auth_get_policy()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/audit.sh  — PERSON 2
# ---------------------------------------------------------------------------
cat > lib/audit.sh << 'SH'
#!/usr/bin/env bash
# lib/audit.sh — HMAC-SHA256 chained tamper-evident audit log
# OWNER: Person 2 (Auth, Policies & Audit)
#
# Public API:
#   audit_append <module> <token_id> <op> <path> <result>
#     Appends one JSON entry to STRONGBOX_AUDIT_LOG.
#     Each entry includes: ts, token, op, path, result, entry_hash, prev_hash.
#     entry_hash = HMAC-SHA256(STRONGBOX_AUDIT_SECRET, prev_hash || ts || token || op || path || result)
#
#   audit_get <token_id>
#     Prints JSON array of entries for a given token.
#
# The verify tool (bin/strongbox-verify) re-derives every hash from genesis
# and exits non-zero naming the first bad index.
#
# STRONGBOX_AUDIT_SECRET is a server-held HMAC key (generated at init, kept in memory).
# STRONGBOX_AUDIT_LOG    is the append-only log file path.

set -euo pipefail

STRONGBOX_AUDIT_LOG="${STRONGBOX_AUDIT_LOG:-/var/lib/strongbox/audit.log}"
STRONGBOX_AUDIT_SECRET="${STRONGBOX_AUDIT_SECRET:-}"  # must be set before use

# TODO: implement audit_append
# TODO: implement audit_get
# TODO: implement _audit_hmac <data>  (uses STRONGBOX_AUDIT_SECRET)
# TODO: implement _audit_prev_hash    (reads last entry's hash from log)

audit_append() { echo "NOT_IMPLEMENTED" >&2; return 1; }
audit_get()    { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/lease.sh  — PERSON 3
# ---------------------------------------------------------------------------
cat > lib/lease.sh << 'SH'
#!/usr/bin/env bash
# lib/lease.sh — Lease lifecycle management + background reaper
# OWNER: Person 3 (Leases & Dynamic Postgres)
#
# Public API:
#   lease_create <path> <ttl> <max_ttl>   -> prints lease JSON {id, ttl, expires_at, state}
#   lease_renew  <lease_id>               -> prints updated lease JSON; exit 1 if expired/revoked
#   lease_revoke <lease_id>               -> exit 0
#   lease_get    <lease_id>               -> prints lease JSON; exit 1 if not found
#   lease_reaper_start                    -> launches background reaper loop (non-blocking)
#
# Lease states: active | expired | revoked | revocation_pending
#
# Reaper behaviour:
#   - Runs every N seconds (configurable, default 30s)
#   - For expired leases tied to dynamic secrets: calls dynamic_revoke_credential
#   - If target DB unreachable: sets state=revocation_pending, retries with exponential backoff
#   - Never silently drops a failed revocation
#   - Eventual success drives role removal without manual intervention

set -euo pipefail

declare -gA _LEASES=()   # lease_id -> JSON blob

# TODO: implement lease_create
# TODO: implement lease_renew  (reject if state != active or past max_ttl)
# TODO: implement lease_revoke
# TODO: implement lease_get
# TODO: implement lease_reaper_start (background loop via & subshell)
# TODO: implement _lease_reaper_loop (iterate expired leases, call dynamic_revoke_credential)
# TODO: implement _lease_generate_id -> prints unique opaque id

lease_create()       { echo "NOT_IMPLEMENTED" >&2; return 1; }
lease_renew()        { echo "NOT_IMPLEMENTED" >&2; return 1; }
lease_revoke()       { echo "NOT_IMPLEMENTED" >&2; return 1; }
lease_get()          { echo "NOT_IMPLEMENTED" >&2; return 1; }
lease_reaper_start() { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/dynamic.sh  — PERSON 3
# ---------------------------------------------------------------------------
cat > lib/dynamic.sh << 'SH'
#!/usr/bin/env bash
# lib/dynamic.sh — Dynamic PostgreSQL credential engine
# OWNER: Person 3 (Leases & Dynamic Postgres)
#
# Public API:
#   dynamic_postgres_read <role_name>
#     Connects to target DB, creates a fresh role, GRANTs privileges,
#     calls lease_create, returns JSON {username, password, lease}.
#
#   dynamic_revoke_credential <username> <lease_id>
#     Connects to target DB, REVOKEs and DROPs the role.
#     If DB unreachable: returns exit code 2 (reaper sets revocation_pending).
#     Must never silently succeed without actually dropping the role.
#
# Config (from environment):
#   STRONGBOX_PG_HOST   STRONGBOX_PG_PORT   STRONGBOX_PG_DB
#   STRONGBOX_PG_USER   STRONGBOX_PG_PASS   (admin credentials for role management)
#   STRONGBOX_PG_GRANT  (e.g. "SELECT ON ALL TABLES IN SCHEMA public")

set -euo pipefail

STRONGBOX_PG_HOST="${STRONGBOX_PG_HOST:-localhost}"
STRONGBOX_PG_PORT="${STRONGBOX_PG_PORT:-5432}"
STRONGBOX_PG_DB="${STRONGBOX_PG_DB:-postgres}"
STRONGBOX_PG_USER="${STRONGBOX_PG_USER:-postgres}"
STRONGBOX_PG_PASS="${STRONGBOX_PG_PASS:-}"
STRONGBOX_PG_GRANT="${STRONGBOX_PG_GRANT:-SELECT ON ALL TABLES IN SCHEMA public}"

# TODO: implement dynamic_postgres_read <role_name>
#   - generate random username + password
#   - PGPASSWORD=... psql ... -c "CREATE ROLE ... LOGIN PASSWORD '...'"
#   - PGPASSWORD=... psql ... -c "GRANT $STRONGBOX_PG_GRANT TO ..."
#   - lease_create "dynamic-postgres/$role_name" ...
#   - print JSON {username, password, lease}

# TODO: implement dynamic_revoke_credential <username> <lease_id>
#   - PGPASSWORD=... psql ... -c "REVOKE ... FROM $username"
#   - PGPASSWORD=... psql ... -c "DROP ROLE IF EXISTS $username"
#   - exit 0 on success, exit 2 on DB unreachable

# TODO: implement _dynamic_pg_exec <sql>  (wraps psql, returns exit 2 on conn failure)
# TODO: implement _dynamic_gen_username <role_name>  -> "sb_<role>_<random8>"
# TODO: implement _dynamic_gen_password               -> 24-char random

dynamic_postgres_read()      { echo "NOT_IMPLEMENTED" >&2; return 1; }
dynamic_revoke_credential()  { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/consensus.sh  — PERSON 4
# ---------------------------------------------------------------------------
cat > lib/consensus.sh << 'SH'
#!/usr/bin/env bash
# lib/consensus.sh — Hand-rolled leader election (Raft-inspired)
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# Public API:
#   consensus_start                -> launches election + heartbeat loops (non-blocking)
#   consensus_is_leader            -> exit 0 if this node is current leader
#   consensus_leader_addr          -> prints "host:port" of current leader
#   consensus_current_term         -> prints current term integer
#   consensus_handle_vote_request  <body_json>  -> prints JSON response
#   consensus_handle_heartbeat     <body_json>  -> exit 0
#
# Rules:
#   - Each node has a term number, vote record, and role (follower/candidate/leader)
#   - Election timeout: random 150-300ms; on timeout, node increments term, votes for self, requests votes
#   - Leader sends heartbeats every 50ms; resets follower timeout
#   - A node votes for at most one candidate per term
#   - Writes accepted by leader only; followers return 307 with leader hint
#   - Reads may be served from followers (document staleness in README)
#   - Minority partition (< quorum) refuses writes
#   - NO external raft/etcd libraries — implement yourself

set -euo pipefail

_CONSENSUS_ROLE="follower"      # follower | candidate | leader
_CONSENSUS_TERM=0
_CONSENSUS_LEADER=""
_CONSENSUS_VOTED_FOR=""
_CONSENSUS_VOTES=0

STRONGBOX_PEERS="${STRONGBOX_PEERS:-}"   # comma-separated "host:port,host:port"
STRONGBOX_NODE_ADDR="${STRONGBOX_NODE_ADDR:-localhost:8200}"

# TODO: implement consensus_start           (spawns _consensus_election_loop & _consensus_heartbeat_loop)
# TODO: implement _consensus_election_loop  (random timeout, request votes, tally)
# TODO: implement _consensus_heartbeat_loop (leader only: broadcast heartbeat to peers)
# TODO: implement consensus_is_leader
# TODO: implement consensus_leader_addr
# TODO: implement consensus_current_term
# TODO: implement consensus_handle_vote_request  (grant vote if term >= current and not yet voted)
# TODO: implement consensus_handle_heartbeat     (reset election timeout, update leader/term)
# TODO: implement _consensus_request_vote <peer>
# TODO: implement _consensus_quorum              -> ceil((peers+1)/2)

consensus_start()               { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_is_leader()           { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_leader_addr()         { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_current_term()        { echo "0"; }
consensus_handle_vote_request() { echo "NOT_IMPLEMENTED" >&2; return 1; }
consensus_handle_heartbeat()    { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# lib/http.sh  — PERSON 4
# ---------------------------------------------------------------------------
cat > lib/http.sh << 'SH'
#!/usr/bin/env bash
# lib/http.sh — HTTP request routing and response helpers
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# Public API:
#   http_serve <bind_addr> <port>       -> blocking HTTP server loop (netcat/socat based)
#   http_respond <status_code> <body>   -> writes HTTP response to stdout (used inside handlers)
#   http_parse_request                  -> parses stdin into _HTTP_METHOD, _HTTP_PATH,
#                                          _HTTP_QUERY, _HTTP_HEADERS, _HTTP_BODY, _HTTP_TOKEN
#
# Routing table (all routes, dispatch to handler functions defined in bin/strongbox):
#
#   SEALED state: only /v1/sys/health and /v1/sys/unseal respond; all else -> 503
#
#   POST   /v1/sys/init                    -> handle_sys_init
#   POST   /v1/sys/unseal                  -> handle_sys_unseal
#   POST   /v1/sys/seal                    -> handle_sys_seal
#   GET    /v1/sys/health                  -> handle_sys_health
#
#   PUT    /v1/secrets/{path}              -> handle_secret_write
#   GET    /v1/secrets/{path}              -> handle_secret_read
#   DELETE /v1/secrets/{path}              -> handle_secret_delete
#
#   GET    /v1/dynamic-postgres/{role}     -> handle_dynamic_postgres_read
#
#   POST   /v1/auth/login                  -> handle_auth_login
#   POST   /v1/auth/revoke                 -> handle_auth_revoke
#   GET    /v1/auth/self                   -> handle_auth_self
#
#   PUT    /v1/policies/{name}             -> handle_policy_write
#   GET    /v1/policies/{name}             -> handle_policy_read
#
#   POST   /v1/leases/{id}/renew           -> handle_lease_renew
#   POST   /v1/leases/{id}/revoke          -> handle_lease_revoke
#
#   GET    /v1/audit                       -> handle_audit_query
#
#   POST   /v1/internal/vote               -> consensus_handle_vote_request  (peer-to-peer)
#   POST   /v1/internal/heartbeat          -> consensus_handle_heartbeat      (peer-to-peer)

set -euo pipefail

_HTTP_METHOD=""
_HTTP_PATH=""
_HTTP_QUERY=""
_HTTP_BODY=""
_HTTP_TOKEN=""

# TODO: implement http_serve    (socat or netcat loop; one process per connection)
# TODO: implement http_respond  (print "HTTP/1.1 <code> ...\r\nContent-Type: application/json\r\n\r\n<body>")
# TODO: implement http_parse_request  (read method/path/headers/body from stdin)
# TODO: implement _http_route   (match method+path to handler; enforce sealed check)
# TODO: implement _http_extract_token  (parse "Authorization: Bearer <token>" header)
# TODO: implement _http_extract_query_param <name>  -> value or empty string

http_serve()   { echo "NOT_IMPLEMENTED" >&2; return 1; }
http_respond() { echo "NOT_IMPLEMENTED" >&2; return 1; }
SH

# ---------------------------------------------------------------------------
# bin/strongbox  — PERSON 1 (owns), integrates all modules
# ---------------------------------------------------------------------------
cat > bin/strongbox << 'SH'
#!/usr/bin/env bash
# bin/strongbox — Main server entrypoint
# OWNER: Person 1 (Crypto, Storage & Seal/Unseal)
#
# This file:
#   1. Sources all lib/*.sh modules
#   2. Defines route handlers for sys/* and secrets/*
#   3. Manages the seal/unseal state machine
#   4. Calls http_serve to start the server
#
# Route handlers owned by OTHER persons are thin wrappers that call into
# their respective lib/*.sh functions. Person 1 only implements:
#   handle_sys_init, handle_sys_unseal, handle_sys_seal, handle_sys_health
#   handle_secret_write, handle_secret_read, handle_secret_delete
#
# Config env vars (also see config.yaml):
#   STRONGBOX_NODE_ID      STRONGBOX_BIND_ADDR   STRONGBOX_PORT
#   STRONGBOX_SHAMIR_K     STRONGBOX_SHAMIR_N    STRONGBOX_DATA_DIR
#   STRONGBOX_AUDIT_LOG    STRONGBOX_LEASE_TTL   STRONGBOX_LEASE_MAX

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/crypto.sh"
source "$LIB_DIR/storage.sh"
source "$LIB_DIR/auth.sh"
source "$LIB_DIR/audit.sh"
source "$LIB_DIR/lease.sh"
source "$LIB_DIR/dynamic.sh"
source "$LIB_DIR/consensus.sh"
source "$LIB_DIR/http.sh"

# ---------------------------------------------------------------------------
# Global state
STRONGBOX_SEALED="true"
STRONGBOX_INIT="false"
declare -a _UNSEAL_SHARES=()
_UNSEAL_PROGRESS=0

# Defaults
STRONGBOX_NODE_ID="${STRONGBOX_NODE_ID:-node1}"
STRONGBOX_BIND_ADDR="${STRONGBOX_BIND_ADDR:-0.0.0.0}"
STRONGBOX_PORT="${STRONGBOX_PORT:-8200}"
STRONGBOX_SHAMIR_K="${STRONGBOX_SHAMIR_K:-3}"
STRONGBOX_SHAMIR_N="${STRONGBOX_SHAMIR_N:-5}"
STRONGBOX_DATA_DIR="${STRONGBOX_DATA_DIR:-/var/lib/strongbox}"
STRONGBOX_AUDIT_LOG="${STRONGBOX_AUDIT_LOG:-${STRONGBOX_DATA_DIR}/audit.log}"
STRONGBOX_LEASE_TTL="${STRONGBOX_LEASE_TTL:-3600}"
STRONGBOX_LEASE_MAX="${STRONGBOX_LEASE_MAX:-86400}"
STRONGBOX_INIT_FILE="${STRONGBOX_DATA_DIR}/.initialized"

# ---------------------------------------------------------------------------
# Helpers
_is_sealed()      { [[ "$STRONGBOX_SEALED" == "true" ]]; }
_is_initialized() { [[ -f "$STRONGBOX_INIT_FILE" ]]; }
_assert_unsealed() {
    if _is_sealed; then http_respond 503 '{"error":"vault is sealed"}'; return 1; fi
}

# ---------------------------------------------------------------------------
# TODO (Person 1): implement handle_sys_init
# TODO (Person 1): implement handle_sys_unseal  (collect shares; reconstruct; zero all buffers)
# TODO (Person 1): implement handle_sys_seal
# TODO (Person 1): implement handle_sys_health
# TODO (Person 1): implement handle_secret_write
# TODO (Person 1): implement handle_secret_read
# TODO (Person 1): implement handle_secret_delete
# TODO (Person 1): implement _unseal_zero_shares

# ---------------------------------------------------------------------------
# Thin wrappers — other persons fill the lib implementations, not this file

handle_auth_login()             { auth_login "$@"; }
handle_auth_revoke()            { auth_revoke_token "$@"; }
handle_auth_self()              { auth_token_info "$@"; }
handle_policy_write()           { auth_create_policy "$@"; }
handle_policy_read()            { auth_get_policy "$@"; }
handle_lease_renew()            { lease_renew "$@"; }
handle_lease_revoke()           { lease_revoke "$@"; }
handle_audit_query()            { audit_get "$@"; }
handle_dynamic_postgres_read()  { dynamic_postgres_read "$@"; }

# ---------------------------------------------------------------------------
_shutdown() {
    echo "[strongbox] shutting down" >&2
    crypto_unload_kek
    exit 0
}
trap _shutdown SIGTERM SIGINT

main() {
    mkdir -p "$STRONGBOX_DATA_DIR"
    _is_initialized && STRONGBOX_INIT="true"
    echo "[strongbox] node=$STRONGBOX_NODE_ID port=$STRONGBOX_PORT state=SEALED" >&2
    lease_reaper_start
    consensus_start
    http_serve "$STRONGBOX_BIND_ADDR" "$STRONGBOX_PORT"
}

main "$@"
SH
chmod +x bin/strongbox

# ---------------------------------------------------------------------------
# bin/strongbox-verify  — PERSON 2
# ---------------------------------------------------------------------------
cat > bin/strongbox-verify << 'SH'
#!/usr/bin/env bash
# bin/strongbox-verify — Audit log tamper verification
# OWNER: Person 2 (Auth, Policies & Audit)
#
# Usage:
#   strongbox-verify <audit_log_file>
#
# Behaviour:
#   Reads every entry in the log from genesis.
#   Re-derives each entry's HMAC from the chain: HMAC(prev_hash || entry_fields).
#   If any entry's stored hash != re-derived hash:
#     exits non-zero and prints the bad entry index and entry content.
#   If all entries are valid: exits 0 and prints "OK: N entries verified".
#
# Requires STRONGBOX_AUDIT_SECRET to be set in the environment (or loaded from
# a sealed key file that this tool knows how to open).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/audit.sh"

# TODO: implement verify logic
#   1. Read log file line by line (each line is a JSON entry)
#   2. For each entry at index i:
#      a. Extract stored entry_hash and prev_hash from JSON
#      b. Re-derive: hmac = HMAC-SHA256(STRONGBOX_AUDIT_SECRET, prev_hash || ts || token || op || path || result)
#      c. Compare; on mismatch: print "TAMPERED: entry $i: <entry>" and exit 1
#   3. Verify prev_hash chain links (entry[i].prev_hash == entry[i-1].entry_hash)
#   4. On success: print "OK: $i entries verified"; exit 0

LOG_FILE="${1:-}"
if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
    echo "Usage: strongbox-verify <audit_log_file>" >&2
    exit 1
fi

echo "NOT IMPLEMENTED" >&2
exit 1
SH
chmod +x bin/strongbox-verify

# ---------------------------------------------------------------------------
# nginx/nginx.conf  — PERSON 4
# ---------------------------------------------------------------------------
cat > nginx/nginx.conf << 'NGINX'
# nginx/nginx.conf — TLS reverse proxy for 3-node StrongBox cluster
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# TODO: configure upstream block for 3 StrongBox nodes
# TODO: configure TLS (Let's Encrypt certs at /etc/letsencrypt/live/<domain>/)
# TODO: proxy_pass to upstream with health checks
# TODO: set appropriate headers: X-Real-IP, X-Forwarded-For, Host

events { worker_connections 1024; }

http {
    # TODO: upstream strongbox { server node1:8200; server node2:8201; server node3:8202; }

    server {
        listen 443 ssl;
        server_name _;  # TODO: replace with your domain

        # TODO: ssl_certificate     /etc/letsencrypt/live/<domain>/fullchain.pem;
        # TODO: ssl_certificate_key /etc/letsencrypt/live/<domain>/privkey.pem;

        location / {
            # TODO: proxy_pass http://strongbox;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 30s;
        }
    }

    server {
        listen 80;
        return 301 https://$host$request_uri;
    }
}
NGINX

# ---------------------------------------------------------------------------
# compose.yaml  — PERSON 4
# ---------------------------------------------------------------------------
cat > compose.yaml << 'YAML'
# compose.yaml — 3-node StrongBox cluster + PostgreSQL
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
#
# TODO: fill in image builds, volume mounts, network config, env vars

version: "3.9"

networks:
  strongbox-net:
    driver: bridge

volumes:
  node1-data:
  node2-data:
  node3-data:
  pg-data:

services:

  # ---------- StrongBox nodes ----------
  node1:
    build: .
    # TODO: command: ["/app/bin/strongbox"]
    environment:
      STRONGBOX_NODE_ID: node1
      STRONGBOX_PORT: "8200"
      STRONGBOX_SHAMIR_K: "3"
      STRONGBOX_SHAMIR_N: "5"
      STRONGBOX_PEERS: "node2:8201,node3:8202"
      STRONGBOX_NODE_ADDR: "node1:8200"
      STRONGBOX_DATA_DIR: /var/lib/strongbox
      STRONGBOX_PG_HOST: postgres
      STRONGBOX_PG_PORT: "5432"
      STRONGBOX_PG_DB: strongbox
      STRONGBOX_PG_USER: sbadmin
      STRONGBOX_PG_PASS: "${POSTGRES_PASSWORD}"
    volumes:
      - node1-data:/var/lib/strongbox
    networks: [strongbox-net]
    depends_on: [postgres]
    # TODO: healthcheck, restart policy

  node2:
    build: .
    environment:
      STRONGBOX_NODE_ID: node2
      STRONGBOX_PORT: "8201"
      STRONGBOX_SHAMIR_K: "3"
      STRONGBOX_SHAMIR_N: "5"
      STRONGBOX_PEERS: "node1:8200,node3:8202"
      STRONGBOX_NODE_ADDR: "node2:8201"
      STRONGBOX_DATA_DIR: /var/lib/strongbox
      STRONGBOX_PG_HOST: postgres
      STRONGBOX_PG_PORT: "5432"
      STRONGBOX_PG_DB: strongbox
      STRONGBOX_PG_USER: sbadmin
      STRONGBOX_PG_PASS: "${POSTGRES_PASSWORD}"
    volumes:
      - node2-data:/var/lib/strongbox
    networks: [strongbox-net]
    depends_on: [postgres]

  node3:
    build: .
    environment:
      STRONGBOX_NODE_ID: node3
      STRONGBOX_PORT: "8202"
      STRONGBOX_SHAMIR_K: "3"
      STRONGBOX_SHAMIR_N: "5"
      STRONGBOX_PEERS: "node1:8200,node2:8201"
      STRONGBOX_NODE_ADDR: "node3:8202"
      STRONGBOX_DATA_DIR: /var/lib/strongbox
      STRONGBOX_PG_HOST: postgres
      STRONGBOX_PG_PORT: "5432"
      STRONGBOX_PG_DB: strongbox
      STRONGBOX_PG_USER: sbadmin
      STRONGBOX_PG_PASS: "${POSTGRES_PASSWORD}"
    volumes:
      - node3-data:/var/lib/strongbox
    networks: [strongbox-net]
    depends_on: [postgres]

  # ---------- Nginx TLS proxy ----------
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      # TODO: mount Let's Encrypt certs
      # - /etc/letsencrypt:/etc/letsencrypt:ro
    networks: [strongbox-net]
    depends_on: [node1, node2, node3]

  # ---------- PostgreSQL (dynamic secrets target) ----------
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: strongbox
      POSTGRES_USER: sbadmin
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
    volumes:
      - pg-data:/var/lib/postgresql/data
    networks: [strongbox-net]
    # TODO: healthcheck
YAML

# ---------------------------------------------------------------------------
# config.yaml  — shared reference config
# ---------------------------------------------------------------------------
cat > config.yaml << 'YAML'
# config.yaml — StrongBox cluster configuration reference
# Environment variables take precedence over these values.
# Load with: source <(python3 -c "import yaml,os,sys; ...")
# Or pass directly as Docker env vars (see compose.yaml).

node_id: ""           # REQUIRED: unique per node (node1 / node2 / node3)
bind_addr: "0.0.0.0"
port: 8200

shamir:
  k: 3                # shares required to unseal
  n: 5                # total shares generated

data_dir: "/var/lib/strongbox"
audit_log: "/var/lib/strongbox/audit.log"

lease:
  default_ttl: 3600   # seconds
  max_ttl: 86400      # seconds
  reaper_interval: 30 # seconds between reaper runs

cluster:
  peers: []           # ["node2:8201", "node3:8202"]
  node_addr: ""       # this node's advertised address "host:port"
  election_timeout_min_ms: 150
  election_timeout_max_ms: 300
  heartbeat_interval_ms: 50

postgres:
  host: "localhost"
  port: 5432
  db: "strongbox"
  user: "sbadmin"
  password: ""        # use STRONGBOX_PG_PASS env var in production
  grant: "SELECT ON ALL TABLES IN SCHEMA public"
YAML

# ---------------------------------------------------------------------------
# Dockerfile  — PERSON 4
# ---------------------------------------------------------------------------
cat > Dockerfile << 'DOCKER'
# Dockerfile
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    openssl \
    argon2 \
    python3 \
    python3-pip \
    socat \
    netcat-openbsd \
    postgresql-client \
    xxd \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app/

RUN chmod +x bin/strongbox bin/strongbox-verify lib/shamir.py

# TODO: set ENTRYPOINT / CMD
# ENTRYPOINT ["/app/bin/strongbox"]

EXPOSE 8200
DOCKER

# ---------------------------------------------------------------------------
# test/integration/test_person1.sh  — PERSON 1
# ---------------------------------------------------------------------------
cat > test/integration/test_person1.sh << 'SH'
#!/usr/bin/env bash
# test/integration/test_person1.sh
# OWNER: Person 1
# Tests: Shamir round-trips, crypto encrypt/decrypt, storage versioning, seal/unseal

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }
_assert_eq() { [[ "$2" == "$3" ]] && _ok "$1" || _fail "$1 (got='$2' want='$3')"; }
_assert_ne() { [[ "$2" != "$3" ]] && _ok "$1" || _fail "$1 (should differ)"; }

# TODO: add Shamir 2-of-3 and 3-of-5 round-trip tests
# TODO: add crypto_encrypt_secret / crypto_decrypt_secret tests
# TODO: add storage versioning tests (put, get, get?version=N, delete, list)
# TODO: add seal/unseal state machine tests
# TODO: add memory hygiene assertions (STRONGBOX_KEK unset after seal)

echo "Person 1 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
SH
chmod +x test/integration/test_person1.sh

# ---------------------------------------------------------------------------
# test/integration/test_person2.sh  — PERSON 2
# ---------------------------------------------------------------------------
cat > test/integration/test_person2.sh << 'SH'
#!/usr/bin/env bash
# test/integration/test_person2.sh
# OWNER: Person 2
# Tests: token creation, policy enforcement, revocation, audit chain, verify tool

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# TODO: test auth_create_token + auth_validate_token (allowed path/cap)
# TODO: test policy enforcement: read-only token -> 200 on read, 403 on write
# TODO: test revocation: revoke token -> next call fails immediately (no grace)
# TODO: test audit_append -> audit log grows
# TODO: test strongbox-verify passes on clean log
# TODO: test strongbox-verify exits non-zero after single-byte tamper, names entry

echo "Person 2 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
SH
chmod +x test/integration/test_person2.sh

# ---------------------------------------------------------------------------
# test/integration/test_person3.sh  — PERSON 3
# ---------------------------------------------------------------------------
cat > test/integration/test_person3.sh << 'SH'
#!/usr/bin/env bash
# test/integration/test_person3.sh
# OWNER: Person 3
# Tests: lease lifecycle, dynamic postgres role creation/revocation, reaper

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# TODO: test lease_create -> active state
# TODO: test lease_renew  -> extends TTL
# TODO: test lease_renew  -> fails after max_ttl
# TODO: test lease_revoke -> state becomes revoked
# TODO: test dynamic_postgres_read -> role exists in pg_roles, creds work
# TODO: test dynamic_revoke_credential -> role gone from pg_roles
# TODO: test DB-unreachable path -> state becomes revocation_pending
# TODO: test reaper eventually cleans up revocation_pending leases when DB returns

echo "Person 3 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
SH
chmod +x test/integration/test_person3.sh

# ---------------------------------------------------------------------------
# test/integration/test_person4.sh  — PERSON 4
# ---------------------------------------------------------------------------
cat > test/integration/test_person4.sh << 'SH'
#!/usr/bin/env bash
# test/integration/test_person4.sh
# OWNER: Person 4
# Tests: leader election, sealed 503, follower redirect, partition behaviour

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

PASS=0; FAIL=0
_ok()   { echo "  PASS: $1"; (( PASS++ )); }
_fail() { echo "  FAIL: $1"; (( FAIL++ )); }

# TODO: start 3-node cluster, assert all sealed
# TODO: unseal all nodes, assert one leader elected
# TODO: write via leader, read via follower (staleness documented)
# TODO: kill leader, assert new leader elected, cluster still serves writes
# TODO: network partition 2-1: assert majority serves writes, minority refuses
# TODO: sealed node returns 503 on all routes except /sys/health and /sys/unseal

echo "Person 4 tests: NOT YET IMPLEMENTED"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
SH
chmod +x test/integration/test_person4.sh

# ---------------------------------------------------------------------------
# test/integration/test_grading.sh  — ALL PERSONS (integration smoke test)
# ---------------------------------------------------------------------------
cat > test/integration/test_grading.sh << 'SH'
#!/usr/bin/env bash
# test/integration/test_grading.sh
# Full end-to-end simulation of all 10 grading scenarios against a live cluster.
# Run AFTER the cluster is up: CLUSTER_URL=https://your-domain bash test_grading.sh
#
# Each scenario is independent. No manual intervention between them.

set -euo pipefail

CLUSTER="${CLUSTER_URL:-https://localhost}"
PASS=0; FAIL=0

_ok()   { echo "  [PASS] $1"; (( PASS++ )); }
_fail() { echo "  [FAIL] $1"; (( FAIL++ )); }

# TODO Scenario 1:  cluster boots sealed; secret write returns 503
# TODO Scenario 2:  submit K shares; cluster transitions to unsealed
# TODO Scenario 3:  write secret/app/db; read it back; second write = v2; get?version=1 = v1
# TODO Scenario 4:  read-policy token: GET secret/app/db=200, PUT=403, GET secret/other/x=403
# TODO Scenario 5:  create token; revoke; next request = 401 (no cache grace)
# TODO Scenario 6:  GET dynamic-postgres/readonly; verify role in pg_roles; creds work
# TODO Scenario 7:  stop postgres; wait past TTL; restart; role cleaned up automatically
# TODO Scenario 8:  kill leader mid-write; write fails cleanly or completes durably; never both ack'd and lost
# TODO Scenario 9:  partition 2-1 > election timeout; majority writes ok; minority refuses
# TODO Scenario 10: tamper one byte in audit log; strongbox-verify exits non-zero naming entry

echo ""
echo "Grading simulation: Passed=$PASS  Failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
SH
chmod +x test/integration/test_grading.sh

# ---------------------------------------------------------------------------
# docs/ placeholder files
# ---------------------------------------------------------------------------
cat > docs/threat-model.md << 'MD'
# StrongBox Threat Model

## What we protect against

<!-- TODO (assign to a person): fill in threat model -->

- Secrets at rest: encrypted with per-secret DEK, DEK wrapped by in-memory KEK
- Insider access to disk: KEK never written to disk; attacker with disk access cannot decrypt
- Replay of audit entries: HMAC chain makes insertion/deletion/modification detectable
- Stolen token: instant revocation, no cache window
- Single-node compromise: Shamir K-of-N prevents single-node unseal
- Brute-force passwords: Argon2id with configured cost parameters

## What we do NOT protect against

- Attacker with full memory access to an unsealed node (KEK is in memory)
- Compromise of all K unseal share holders simultaneously
- Denial of service attacks
- Side-channel attacks on the cryptographic operations
- Kubernetes / orchestration-layer attacks (we run on raw Docker Compose)

## Nonce strategy

AES-256-GCM with 96-bit random nonces from /dev/urandom.
Collision probability is negligible for expected secret counts (< 2^32 encryptions per KEK lifetime).
The KEK is rotated on every seal/unseal cycle.

## Election protocol

<!-- TODO (Person 4): describe your election protocol (200-400 words) -->

## DB-unreachable revocation

<!-- TODO (Person 3): describe revocation_pending retry behaviour -->

## Seal/unseal memory hygiene

<!-- TODO (Person 1): describe what is zeroed, when, and how you verified it -->
MD

cat > docs/architecture.png.placeholder << 'TXT'
Replace this file with docs/architecture.png
Required content: diagram showing 3-node cluster, nginx, postgres, seal/unseal flow,
encryption layers (DEK -> KEK -> Shamir shares), auth/policy flow, audit chain.
TXT

# ---------------------------------------------------------------------------
# README.md skeleton
# ---------------------------------------------------------------------------
cat > README.md << 'MD'
# StrongBox — Distributed Secrets Manager

<!-- TODO: fill in public cluster URL -->
**Cluster URL:** `https://your-domain.example.com`

**GitHub repo:** `https://github.com/your-org/strongbox`

---

## Quick start (grader setup)

```bash
# 1. Clone and deploy
git clone https://github.com/your-org/strongbox
cd strongbox
cp .env.example .env   # fill in POSTGRES_PASSWORD and domain
docker compose up -d

# 2. Initialize (one-time)
curl -s -X POST https://your-domain/v1/sys/init | tee init-output.json
# Save the shares and root_token from init-output.json

# 3. Unseal (submit K=3 shares)
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share1>"}'
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share2>"}'
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share3>"}'

# 4. Create a scoped token for grading
curl -s -X POST https://your-domain/v1/policies/grader \
  -H "Authorization: Bearer <root_token>" \
  -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}'

curl -s -X POST https://your-domain/v1/auth/login \
  -d '{"username":"grader","password":"<password>"}'
```

---

## API examples

<!-- TODO: curl examples for all 10 grading scenarios -->

## Architecture

![Architecture](docs/architecture.png)

<!-- TODO: prose architecture overview -->

## Election protocol

<!-- TODO: 200-400 words on term numbers, vote rules, partition behaviour -->

## DB-unreachable revocation behaviour

<!-- TODO: explain revocation_pending retry with exponential backoff -->

## Seal/unseal memory hygiene

<!-- TODO: what is zeroed, when, and how verified -->

## Threat model

See [docs/threat-model.md](docs/threat-model.md).
MD

# ---------------------------------------------------------------------------
# .env.example
# ---------------------------------------------------------------------------
cat > .env.example << 'ENV'
# Copy to .env and fill in values before running docker compose up
POSTGRES_PASSWORD=change_me_strong_password
# DOMAIN=your-domain.example.com
ENV

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------
cat > .gitignore << 'GIT'
.env
data/
*.log
docs/architecture.png
screenshots/*.png
GIT

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "  [ok] all files written"
echo ""
echo "  Project structure:"
find . -not -path './.git/*' -not -name '.git' | sort | sed 's|^\./||' | \
  awk '{
    n = split($0, a, "/")
    indent = ""
    for (i=1; i<n; i++) indent = indent "  "
    print indent (n>1 ? "├── " : "") a[n]
  }'
echo ""
echo "  Next steps:"
echo "    1. git init && git add . && git commit -m 'chore: project skeleton'"
echo "    2. Each person branches off main and works on their files"
echo "    3. Run bash test/integration/test_person<N>.sh as you go"
echo "    4. Run bash test/integration/test_grading.sh against the live cluster"
echo ""