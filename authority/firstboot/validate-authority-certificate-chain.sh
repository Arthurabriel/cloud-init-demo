#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

WORKLOAD_SPIFFE_ID="${WORKLOAD_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/authority/validation-workload}"
WORKLOAD_SELECTOR="${WORKLOAD_SELECTOR:-unix:uid:0}"
TMP_DIR="$(mktemp -d /tmp/authority-chain.XXXXXX)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${AUTHORITY_SERVER_SOCKET}"
}

authority_agent_id() {
    server agent list -output json | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
for agent in payload.get("agents", []):
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

ensure_validation_entry() {
    local parent_id="$1"
    local exact_entry

    exact_entry="$(
        server entry show \
            -parentID "${parent_id}" \
            -spiffeID "${WORKLOAD_SPIFFE_ID}" \
            -selector "${WORKLOAD_SELECTOR}" 2>/dev/null || true
    )"
    if grep -Fq "Entry ID" <<<"${exact_entry}"; then
        return 0
    fi

    server entry create \
        -parentID "${parent_id}" \
        -spiffeID "${WORKLOAD_SPIFFE_ID}" \
        -selector "${WORKLOAD_SELECTOR}" >/dev/null
}

fetch_validation_svid() {
    local attempt

    for attempt in $(seq 1 15); do
        if /opt/spire/bin/spire-agent api fetch x509 \
            -socketPath "${AUTHORITY_AGENT_SOCKET}" \
            -write "${TMP_DIR}" >/dev/null; then
            return 0
        fi
        sleep 2
    done

    echo "[authority-chain] could not fetch validation SVID from ${AUTHORITY_AGENT_SOCKET}" >&2
    echo "[authority-chain] expected SPIFFE ID: ${WORKLOAD_SPIFFE_ID}" >&2
    echo "[authority-chain] expected parent ID: ${PARENT_ID}" >&2
    echo "[authority-chain] expected selector: ${WORKLOAD_SELECTOR}" >&2
    echo "[authority-chain] exact matching entries:" >&2
    server entry show \
        -parentID "${PARENT_ID}" \
        -spiffeID "${WORKLOAD_SPIFFE_ID}" \
        -selector "${WORKLOAD_SELECTOR}" >&2 || true
    echo "[authority-chain] recent authority agent logs:" >&2
    journalctl -u spire-agent-authority.service --no-pager -n 80 >&2 || true
    return 1
}

split_chain() {
    awk '
        /BEGIN CERTIFICATE/ { n++; file=sprintf("'"${TMP_DIR}"'/cert-%02d.pem", n) }
        { if (n > 0) print > file }
    ' "${TMP_DIR}/svid.0.pem"
}

main() {
    PARENT_ID="$(authority_agent_id)"
    if [[ -z "${PARENT_ID}" ]]; then
        echo "[authority-chain] no attested authority agent found" >&2
        exit 1
    fi

    ensure_validation_entry "${PARENT_ID}"

    fetch_validation_svid

    if [[ ! -f "${TMP_DIR}/svid.0.pem" || ! -f "${TMP_DIR}/bundle.0.pem" ]]; then
        echo "[authority-chain] expected SVID and bundle files were not written to ${TMP_DIR}" >&2
        exit 1
    fi

    split_chain
    if [[ ! -f "${TMP_DIR}/cert-01.pem" ]]; then
        echo "[authority-chain] could not split workload certificate from SVID chain" >&2
        exit 1
    fi

    if [[ -f "${TMP_DIR}/cert-02.pem" ]]; then
        cat "${TMP_DIR}"/cert-0[2-9].pem > "${TMP_DIR}/intermediates.pem"
        openssl verify \
            -CAfile "${TMP_DIR}/bundle.0.pem" \
            -untrusted "${TMP_DIR}/intermediates.pem" \
            "${TMP_DIR}/cert-01.pem"
    else
        openssl verify \
            -CAfile "${TMP_DIR}/bundle.0.pem" \
            "${TMP_DIR}/cert-01.pem"
    fi

    printf '[authority-chain] workload SVID: %s\n' "${WORKLOAD_SPIFFE_ID}"
    printf '[authority-chain] chain verification: OK\n'
    printf '[authority-chain] certificate subjects:\n'
    for cert in "${TMP_DIR}"/cert-*.pem; do
        openssl x509 -in "${cert}" -noout -subject -issuer
    done
}

main "$@"
