#!/usr/bin/env bash
# lib/storage.sh — In-memory storage backend for StrongBox
#
# Interface contract (swap this file for a BoltDB shim in the future):
#
#   storage_put    <path> <encrypted_blob>        → exit 0
#   storage_get    <path> [version]               → encrypted_blob | exit 1 if missing
#   storage_delete <path>                         → exit 0
#   storage_list   <prefix>                       → newline-separated paths
#   storage_latest_version <path>                 → integer version number | exit 1
#
# Versioning:
#   Every PUT creates a new version. Versions are 1-based integers.
#   GET without version returns the latest. GET with version=N returns that version.
#   DELETE marks the path deleted (no further GETs succeed) but preserves history
#   so audit can reference it.
#
# Storage layout (bash associative arrays, process-lifetime):
#   _STORE_VERSIONS[path]       = latest version number (integer)
#   _STORE_DATA[path:N]         = encrypted blob for version N
#   _STORE_DELETED[path]        = "1" if deleted
#
# Thread safety: single-process bash; no locking needed.
# Persistence: intentionally none — in-memory only per spec.

set -euo pipefail

declare -gA _STORE_VERSIONS=()
declare -gA _STORE_DATA=()
declare -gA _STORE_DELETED=()

# ---------------------------------------------------------------------------
# storage_put <path> <encrypted_blob>
# Write a new version of a secret. Clears the deleted flag if re-writing.
# Stdout: new version number
# ---------------------------------------------------------------------------
storage_put() {
    local path="${1:?path required}"
    local blob="${2:?blob required}"

    _storage_validate_path "$path"

    local prev_ver="${_STORE_VERSIONS[$path]:-0}"
    local new_ver=$(( prev_ver + 1 ))

    _STORE_VERSIONS["$path"]="$new_ver"
    _STORE_DATA["${path}:${new_ver}"]="$blob"
    unset '_STORE_DELETED[$path]' 2>/dev/null || true

    printf '%d' "$new_ver"
}

# ---------------------------------------------------------------------------
# storage_get <path> [version]
# Retrieve a secret blob. Returns exit 1 if not found or deleted.
# Stdout: encrypted_blob
# ---------------------------------------------------------------------------
storage_get() {
    local path="${1:?path required}"
    local version="${2:-}"

    _storage_validate_path "$path"

    if [[ -n "${_STORE_DELETED[$path]:-}" ]]; then
        return 1
    fi

    local latest="${_STORE_VERSIONS[$path]:-0}"
    if [[ "$latest" -eq 0 ]]; then
        return 1
    fi

    local target_ver
    if [[ -z "$version" ]]; then
        target_ver="$latest"
    else
        target_ver="$version"
    fi

    if [[ "$target_ver" -lt 1 || "$target_ver" -gt "$latest" ]]; then
        return 1
    fi

    local key="${path}:${target_ver}"
    if [[ -z "${_STORE_DATA[$key]:-}" ]]; then
        return 1
    fi

    printf '%s' "${_STORE_DATA[$key]}"
}

# ---------------------------------------------------------------------------
# storage_delete <path>
# Mark a path as deleted. History is preserved internally.
# ---------------------------------------------------------------------------
storage_delete() {
    local path="${1:?path required}"
    _storage_validate_path "$path"

    if [[ -z "${_STORE_VERSIONS[$path]:-}" ]]; then
        return 1
    fi

    _STORE_DELETED["$path"]="1"
}

# ---------------------------------------------------------------------------
# storage_list <prefix>
# List all active (not deleted) paths under a prefix.
# Stdout: newline-separated paths, sorted.
# ---------------------------------------------------------------------------
storage_list() {
    local prefix="${1:-}"
    local results=()

    for path in "${!_STORE_VERSIONS[@]}"; do
        [[ -n "${_STORE_DELETED[$path]:-}" ]] && continue
        if [[ -z "$prefix" || "$path" == "$prefix"* ]]; then
            results+=("$path")
        fi
    done

    if [[ "${#results[@]}" -gt 0 ]]; then
        printf '%s\n' "${results[@]}" | sort
    fi
}

# ---------------------------------------------------------------------------
# storage_latest_version <path>
# Return the latest version number for a path.
# Exits 1 if path does not exist or is deleted.
# ---------------------------------------------------------------------------
storage_latest_version() {
    local path="${1:?path required}"
    _storage_validate_path "$path"

    if [[ -n "${_STORE_DELETED[$path]:-}" ]]; then
        return 1
    fi

    local v="${_STORE_VERSIONS[$path]:-0}"
    if [[ "$v" -eq 0 ]]; then
        return 1
    fi

    printf '%d' "$v"
}

# ---------------------------------------------------------------------------
# storage_exists <path>
# Returns 0 if path exists and is not deleted, 1 otherwise.
# ---------------------------------------------------------------------------
storage_exists() {
    local path="${1:?}"
    [[ -z "${_STORE_DELETED[$path]:-}" && -n "${_STORE_VERSIONS[$path]:-}" ]]
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_storage_validate_path() {
    local path="${1:?}"
    # Paths must be non-empty, no null bytes, no leading slash required but
    # we disallow .. traversal components.
    if [[ "$path" == *".."* ]]; then
        echo "ERROR: path traversal not allowed: $path" >&2
        return 1
    fi
    if [[ -z "$path" ]]; then
        echo "ERROR: empty path" >&2
        return 1
    fi
}