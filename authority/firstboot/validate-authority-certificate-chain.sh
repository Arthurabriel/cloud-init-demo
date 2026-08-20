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
    local entries
    entries="$(server entry show 2>/dev/null || true)"
    if grep -Fq "SPIFFE ID        : ${WORKLOAD_SPIFFE_ID}" <<<"${entries}"; then
        return 0
    fi

    server entry create \
        -parentID "${parent_id}" \
        -spiffeID "${WORKLOAD_SPIFFE_ID}" \
        -selector "${WORKLOAD_SELECTOR}" >/dev/null
}

split_chain() {
    awk '
        /BEGIN CERTIFICATE/ { n++; file=sprintf("'"${TMP_DIR}"'/cert-%02d.pem", n) }
        { if (n > 0) print > file }
    ' "${TMP_DIR}/svid.0.pem"
}

main() {
    local parent_id
    parent_id="$(authority_agent_id)"
    if [[ -z "${parent_id}" ]]; then
        echo "[authority-chain] no attested authority agent found" >&2
        exit 1
    fi

    ensure_validation_entry "${parent_id}"

    /opt/spire/bin/spire-agent api fetch x509 \
        -socketPath "${AUTHORITY_AGENT_SOCKET}" \
        -write "${TMP_DIR}" >/dev/null

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
