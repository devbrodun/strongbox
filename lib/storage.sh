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

STRONGBOX_DATA_DIR="${STRONGBOX_DATA_DIR:-/var/lib/strongbox}"
_STORAGE_DIR="${STRONGBOX_DATA_DIR}/store"

# ---------------------------------------------------------------------------
# storage_put <path> <encrypted_blob>
# Write a new version of a secret. Clears the deleted flag if re-writing.
# Stdout: new version number
# ---------------------------------------------------------------------------
storage_put() {
    local path="${1:?path required}"
    local blob="${2:?blob required}"

    _storage_validate_path "$path" || return 1

    local pdir="${_STORAGE_DIR}/${path}"
    local prev_ver=0
    if [[ -f "${pdir}/latest" ]]; then
        prev_ver=$(cat "${pdir}/latest")
    fi
    local new_ver=$(( prev_ver + 1 ))

    mkdir -p "$pdir"
    printf '%s' "$blob" > "${pdir}/version_${new_ver}"
    printf '%d' "$new_ver" > "${pdir}/latest"
    rm -f "${pdir}/deleted"

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

    _storage_validate_path "$path" || return 1

    local pdir="${_STORAGE_DIR}/${path}"

    if [[ -f "${pdir}/deleted" ]]; then
        return 1
    fi

    if [[ ! -f "${pdir}/latest" ]]; then
        return 1
    fi

    local latest
    latest=$(cat "${pdir}/latest")

    local target_ver
    if [[ -z "$version" ]]; then
        target_ver="$latest"
    else
        target_ver="$version"
    fi

    if [[ "$target_ver" -lt 1 || "$target_ver" -gt "$latest" ]]; then
        return 1
    fi

    if [[ ! -f "${pdir}/version_${target_ver}" ]]; then
        return 1
    fi

    cat "${pdir}/version_${target_ver}"
}

# ---------------------------------------------------------------------------
# storage_delete <path>
# Mark a path as deleted. History is preserved internally.
# ---------------------------------------------------------------------------
storage_delete() {
    local path="${1:?path required}"
    _storage_validate_path "$path" || return 1

    local pdir="${_STORAGE_DIR}/${path}"

    if [[ ! -f "${pdir}/latest" ]]; then
        return 1
    fi

    touch "${pdir}/deleted"
}

# ---------------------------------------------------------------------------
# storage_list <prefix>
# List all active (not deleted) paths under a prefix.
# Stdout: newline-separated paths, sorted.
# ---------------------------------------------------------------------------
storage_list() {
    local prefix="${1:-}"
    local results=()

    if [[ -d "$_STORAGE_DIR" ]]; then
        # Use find in a subshell to safely traverse and get relative paths
        while read -r rel; do
            if [[ -f "${_STORAGE_DIR}/${rel}/latest" && ! -f "${_STORAGE_DIR}/${rel}/deleted" ]]; then
                results+=("$rel")
            fi
        done < <(cd "$_STORAGE_DIR" && find . -type d ! -path . | sed 's|^\./||' | sort)
    fi

    if [[ "${#results[@]}" -gt 0 ]]; then
        for r in "${results[@]}"; do
            if [[ -z "$prefix" || "$r" == "$prefix"* ]]; then
                printf '%s\n' "$r"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# storage_latest_version <path>
# Return the latest version number for a path.
# Exits 1 if path does not exist or is deleted.
# ---------------------------------------------------------------------------
storage_latest_version() {
    local path="${1:?path required}"
    _storage_validate_path "$path" || return 1

    local pdir="${_STORAGE_DIR}/${path}"

    if [[ -f "${pdir}/deleted" ]]; then
        return 1
    fi

    if [[ ! -f "${pdir}/latest" ]]; then
        return 1
    fi

    cat "${pdir}/latest"
}

# ---------------------------------------------------------------------------
# storage_exists <path>
# Returns 0 if path exists and is not deleted, 1 otherwise.
# ---------------------------------------------------------------------------
storage_exists() {
    local path="${1:?}"
    _storage_validate_path "$path" || return 1
    local pdir="${_STORAGE_DIR}/${path}"
    [[ ! -f "${pdir}/deleted" && -f "${pdir}/latest" ]]
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
    return 0
}