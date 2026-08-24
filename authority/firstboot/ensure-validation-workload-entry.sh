#!/usr/bin/env bash
set -euo pipefail

# Create (or reuse) the local registration entry the SPIRE Evidence Adapter needs.
#
# The adapter fetches an X.509-SVID from the Authority Agent Workload API to prove the
# chain reaches the Trusted Root. Without this entry the Workload API answers
# "PermissionDenied: no identity issued" and the adapter reports an unusable authority.

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

WORKLOAD_SPIFFE_ID="${WORKLOAD_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/authority/validation-workload}"
WORKLOAD_SELECTOR="${WORKLOAD_SELECTOR:-unix:uid:0}"

log() {
    printf '[validation-entry] %s\n' "$*"
}

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${AUTHORITY_SERVER_SOCKET}"
}

# Resolve the agent belonging to this VM. Taking the first row of agent list is wrong as
# soon as more than one agent attests to this Authority Server.
resolve_authority_agent() {
    local recorded tmp_dir agents_json resolved status
    recorded=""
    if [[ -s "${AUTHORITY_AGENT_NODE_ID_FILE}" ]]; then
        recorded="$(head -n 1 "${AUTHORITY_AGENT_NODE_ID_FILE}")"
    fi

    tmp_dir="$(mktemp -d /tmp/validation-entry.XXXXXX)"
    agents_json="${tmp_dir}/agents.json"
    server agent list -output json > "${agents_json}" 2>/dev/null || true

    set +e
    resolved="$(
        python3 "${AUTHORITY_DIR}/firstboot/resolve-upstream-agent.py" \
            --agents-json "${agents_json}" \
            --expected-node-id "${PARENT_ID:-${recorded}}" \
            --override-var PARENT_ID
    )"
    status=$?
    set -e

    rm -rf "${tmp_dir}"
    if [[ "${status}" -ne 0 ]]; then
        return "${status}"
    fi
    printf '%s\n' "${resolved}"
}

main() {
    local parent_id
    parent_id="$(resolve_authority_agent)"

    if [[ -z "${parent_id}" ]]; then
        exit 1
    fi

    if server entry show \
        -parentID "${parent_id}" \
        -spiffeID "${WORKLOAD_SPIFFE_ID}" \
        -selector "${WORKLOAD_SELECTOR}" 2>/dev/null | grep -Fq "Entry ID"; then
        log "entry already exists for ${WORKLOAD_SPIFFE_ID}"
        printf '%s\n' "${parent_id}"
        return 0
    fi

    log "creating entry ${WORKLOAD_SPIFFE_ID} (parent ${parent_id}, selector ${WORKLOAD_SELECTOR})"
    server entry create \
        -parentID "${parent_id}" \
        -spiffeID "${WORKLOAD_SPIFFE_ID}" \
        -selector "${WORKLOAD_SELECTOR}" >/dev/null

    printf '%s\n' "${parent_id}"
}

main "$@"
