#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

ROOT_SOCKET="${ROOT_SOCKET:-${TRUSTED_ROOT_SERVER_SOCKET}}"
DOWNSTREAM_SPIFFE_ID="${DOWNSTREAM_SPIFFE_ID:-${AUTHORITY_SERVER_SPIFFE_ID}}"
DOWNSTREAM_SELECTOR="${DOWNSTREAM_SELECTOR:-unix:user:spire-server}"
UPSTREAM_AGENT_SPIFFE_ID="${UPSTREAM_AGENT_SPIFFE_ID:-}"

log() {
    printf '[register-downstream-authority] %s\n' "$*"
}

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${ROOT_SOCKET}"
}

find_attested_agent() {
    server agent list -output json | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
agents = payload.get("agents", [])
for agent in agents:
    agent_id = agent.get("id")
    if isinstance(agent_id, str):
        print(agent_id)
        break
    if isinstance(agent_id, dict):
        trust_domain = agent_id.get("trust_domain")
        path = agent_id.get("path")
        if trust_domain and path:
            path = path if str(path).startswith("/") else f"/{path}"
            print(f"spiffe://{trust_domain}{path}")
            break
'
}

entry_exists() {
    local output
    output="$(server entry show 2>/dev/null || true)"
    if ! grep -Fq "SPIFFE ID        : ${DOWNSTREAM_SPIFFE_ID}" <<<"${output}"; then
        return 1
    fi
    if grep -A12 -F "SPIFFE ID        : ${DOWNSTREAM_SPIFFE_ID}" <<<"${output}" | grep -Eq "Downstream[[:space:]]*:[[:space:]]*true"; then
        return 0
    fi
    echo "[register-downstream-authority] existing entry for ${DOWNSTREAM_SPIFFE_ID} is not marked downstream" >&2
    exit 1
}

main() {
    require_var TRUST_DOMAIN
    require_var DOWNSTREAM_SPIFFE_ID

    if [[ -z "${UPSTREAM_AGENT_SPIFFE_ID}" ]]; then
        UPSTREAM_AGENT_SPIFFE_ID="$(find_attested_agent)"
    fi

    if [[ -z "${UPSTREAM_AGENT_SPIFFE_ID}" ]]; then
        echo "[register-downstream-authority] no attested upstream agent found. Start the Authority upstream agent first." >&2
        exit 1
    fi

    log "root socket: ${ROOT_SOCKET}"
    log "upstream agent: ${UPSTREAM_AGENT_SPIFFE_ID}"
    log "downstream server SPIFFE ID: ${DOWNSTREAM_SPIFFE_ID}"
    log "selector: ${DOWNSTREAM_SELECTOR}"

    if entry_exists; then
        log "downstream entry already exists; no change"
        return 0
    fi

    log "creating downstream entry"
    server entry create \
        -parentID "${UPSTREAM_AGENT_SPIFFE_ID}" \
        -spiffeID "${DOWNSTREAM_SPIFFE_ID}" \
        -selector "${DOWNSTREAM_SELECTOR}" \
        -downstream

    log "downstream entry created"
}

main "$@"
