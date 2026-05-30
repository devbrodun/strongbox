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
