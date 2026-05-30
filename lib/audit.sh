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
