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
