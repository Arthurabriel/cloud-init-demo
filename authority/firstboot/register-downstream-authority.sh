#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

ROOT_SOCKET="${ROOT_SOCKET:-${TRUSTED_ROOT_SERVER_SOCKET}}"
DOWNSTREAM_SPIFFE_ID="${DOWNSTREAM_SPIFFE_ID:-${AUTHORITY_SERVER_SPIFFE_ID}}"
DOWNSTREAM_SELECTOR="${DOWNSTREAM_SELECTOR:-unix:user:spire-server}"
UPSTREAM_AGENT_NODE_SPIFFE_ID="${UPSTREAM_AGENT_NODE_SPIFFE_ID:-}"
UPSTREAM_AGENT_ALIAS_SPIFFE_ID="${UPSTREAM_AGENT_ALIAS_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/pgid/agent/openstack/authority-upstream}"
REPLACE_STALE_ENTRIES="${REPLACE_STALE_ENTRIES:-false}"

# UPSTREAM_AGENT_SPIFFE_ID used to mean the alias here and the node ID there. Those are
# different SPIFFE IDs, and feeding the alias to -parentID builds a silently wrong entry,
# so refuse rather than guess which one the operator meant.
if [[ -n "${UPSTREAM_AGENT_SPIFFE_ID:-}" ]]; then
    echo "[register-downstream-authority] UPSTREAM_AGENT_SPIFFE_ID is ambiguous and no longer read here." >&2
    echo "[register-downstream-authority] Use UPSTREAM_AGENT_NODE_SPIFFE_ID for the agent node ID used as -parentID" >&2
    echo "[register-downstream-authority]   (spiffe://${TRUST_DOMAIN}/spire/agent/join_token/<token>)," >&2
    echo "[register-downstream-authority] or UPSTREAM_AGENT_ALIAS_SPIFFE_ID for the alias given to token generate -spiffeID." >&2
    exit 1
fi

log() {
    printf '[register-downstream-authority] %s\n' "$*"
}

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${ROOT_SOCKET}"
}

# Resolve the agent that belongs to *this* Authority. Taking the first row of agent list
# breaks as soon as a second Authority attests to the same Trusted Root.
resolve_upstream_agent() {
    local tmp_dir agents_json alias_json
    tmp_dir="$(mktemp -d /tmp/register-downstream.XXXXXX)"
    agents_json="${tmp_dir}/agents.json"
    alias_json="${tmp_dir}/alias-entries.json"

    server agent list -output json > "${agents_json}" 2>/dev/null || true
    server entry show -spiffeID "${UPSTREAM_AGENT_ALIAS_SPIFFE_ID}" -output json \
        > "${alias_json}" 2>/dev/null || true

    local resolved status
    set +e
    resolved="$(
        python3 "${AUTHORITY_DIR}/firstboot/resolve-upstream-agent.py" \
            --agents-json "${agents_json}" \
            --alias-entries-json "${alias_json}" \
            --expected-node-id "${UPSTREAM_AGENT_NODE_SPIFFE_ID}" \
            --override-var UPSTREAM_AGENT_NODE_SPIFFE_ID
    )"
    status=$?
    set -e

    rm -rf "${tmp_dir}"
    if [[ "${status}" -ne 0 ]]; then
        return "${status}"
    fi
    printf '%s\n' "${resolved}"
}

# Classify every entry that already carries DOWNSTREAM_SPIFFE_ID. Matching on the SPIFFE
# ID alone is not enough: an entry left over from a previous join token keeps that ID but
# points at a dead parent, which leaves the new Authority stuck on "no identity issued".
inspect_entries() {
    server entry show -spiffeID "${DOWNSTREAM_SPIFFE_ID}" -output json 2>/dev/null \
        | python3 "${AUTHORITY_DIR}/firstboot/inspect-downstream-entries.py" \
            --expected-parent "${UPSTREAM_AGENT_NODE_SPIFFE_ID}" \
            --expected-selector "${DOWNSTREAM_SELECTOR}"
}

delete_entry() {
    local entry_id="$1"
    log "deleting stale entry ${entry_id}"
    server entry delete -entryID "${entry_id}"
}

report_stale() {
    local stale_ids="$1"
    echo "[register-downstream-authority] found entries for ${DOWNSTREAM_SPIFFE_ID} that do not match this Authority:" >&2
    inspect_entries | grep '^STALE' >&2 || true
    echo "[register-downstream-authority] expected parent  : ${UPSTREAM_AGENT_NODE_SPIFFE_ID}" >&2
    echo "[register-downstream-authority] expected selector: ${DOWNSTREAM_SELECTOR}" >&2
    echo "[register-downstream-authority] expected downstream: true" >&2
    echo "[register-downstream-authority]" >&2
    echo "[register-downstream-authority] A stale entry keeps the Authority on 'no identity issued'." >&2
    echo "[register-downstream-authority] Rerun with REPLACE_STALE_ENTRIES=true to delete and recreate, or remove them by hand:" >&2
    for entry_id in ${stale_ids}; do
        echo "[register-downstream-authority]   spire-server entry delete -socketPath ${ROOT_SOCKET} -entryID ${entry_id}" >&2
    done
}

main() {
    require_var TRUST_DOMAIN
    require_var DOWNSTREAM_SPIFFE_ID

    UPSTREAM_AGENT_NODE_SPIFFE_ID="$(resolve_upstream_agent)"
    if [[ -z "${UPSTREAM_AGENT_NODE_SPIFFE_ID}" ]]; then
        exit 1
    fi

    log "root socket: ${ROOT_SOCKET}"
    log "upstream agent alias: ${UPSTREAM_AGENT_ALIAS_SPIFFE_ID}"
    log "upstream agent node : ${UPSTREAM_AGENT_NODE_SPIFFE_ID}"
    log "downstream server SPIFFE ID: ${DOWNSTREAM_SPIFFE_ID}"
    log "selector: ${DOWNSTREAM_SELECTOR}"

    local entries match_count stale_ids
    entries="$(inspect_entries)"
    match_count="$(grep -c '^MATCH' <<<"${entries}" || true)"
    stale_ids="$(awk -F'\t' '$1 == "STALE" { print $2 }' <<<"${entries}" | tr '\n' ' ')"
    stale_ids="${stale_ids% }"

    if [[ -n "${stale_ids}" ]]; then
        if [[ "${REPLACE_STALE_ENTRIES}" != "true" ]]; then
            report_stale "${stale_ids}"
            exit 1
        fi
        for entry_id in ${stale_ids}; do
            delete_entry "${entry_id}"
        done
    fi

    if [[ "${match_count}" -gt 0 ]]; then
        log "downstream entry already matches this upstream agent and selector; no change"
        return 0
    fi

    log "creating downstream entry"
    server entry create \
        -parentID "${UPSTREAM_AGENT_NODE_SPIFFE_ID}" \
        -spiffeID "${DOWNSTREAM_SPIFFE_ID}" \
        -selector "${DOWNSTREAM_SELECTOR}" \
        -downstream

    log "downstream entry created"
}

main "$@"
