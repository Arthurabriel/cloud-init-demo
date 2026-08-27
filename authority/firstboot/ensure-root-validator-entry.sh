#!/usr/bin/env bash
set -euo pipefail


AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

ROOT_SOCKET="${ROOT_SOCKET:-${TRUSTED_ROOT_SERVER_SOCKET}}"
ROOT_VALIDATOR_SPIFFE_ID="${ROOT_VALIDATOR_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/authority/root-attested-validator}"
ROOT_VALIDATOR_SELECTOR="${ROOT_VALIDATOR_SELECTOR:-unix:uid:0}"
UPSTREAM_AGENT_NODE_SPIFFE_ID="${UPSTREAM_AGENT_NODE_SPIFFE_ID:-}"
UPSTREAM_AGENT_ALIAS_SPIFFE_ID="${UPSTREAM_AGENT_ALIAS_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/pgid/agent/openstack/authority-upstream}"

log() {
    printf '[ensure-root-validator-entry] %s\n' "$*"
}

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${ROOT_SOCKET}"
}

resolve_upstream_agent() {
    local tmp_dir agents_json alias_json resolved status
    tmp_dir="$(mktemp -d /tmp/root-validator-entry.XXXXXX)"
    agents_json="${tmp_dir}/agents.json"
    alias_json="${tmp_dir}/alias-entries.json"

    server agent list -output json > "${agents_json}" 2>/dev/null || true
    server entry show -spiffeID "${UPSTREAM_AGENT_ALIAS_SPIFFE_ID}" -output json \
        > "${alias_json}" 2>/dev/null || true

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

main() {
    require_var TRUST_DOMAIN
    require_var ROOT_VALIDATOR_SPIFFE_ID

    local parent_id
    parent_id="$(resolve_upstream_agent)"
    if [[ -z "${parent_id}" ]]; then
        exit 1
    fi

    log "root socket: ${ROOT_SOCKET}"
    log "upstream agent node : ${parent_id}"
    log "validator SPIFFE ID : ${ROOT_VALIDATOR_SPIFFE_ID}"
    log "selector: ${ROOT_VALIDATOR_SELECTOR}"

    if server entry show \
        -parentID "${parent_id}" \
        -spiffeID "${ROOT_VALIDATOR_SPIFFE_ID}" \
        -selector "${ROOT_VALIDATOR_SELECTOR}" 2>/dev/null | grep -Fq "Entry ID"; then
        log "entry already exists for ${ROOT_VALIDATOR_SPIFFE_ID}; no change"
        printf '%s\n' "${parent_id}"
        return 0
    fi

    log "creating root-attested validator entry"
    server entry create \
        -parentID "${parent_id}" \
        -spiffeID "${ROOT_VALIDATOR_SPIFFE_ID}" \
        -selector "${ROOT_VALIDATOR_SELECTOR}" >/dev/null

    log "root-attested validator entry created"
    printf '%s\n' "${parent_id}"
}

main "$@"
