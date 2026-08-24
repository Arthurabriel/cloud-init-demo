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

fetch_validation_svid() {
    local attempt fetch_error
    fetch_error="${TMP_DIR}/fetch-error.log"

    for attempt in $(seq 1 15); do
        if /opt/spire/bin/spire-agent api fetch x509 \
            -socketPath "${AUTHORITY_AGENT_SOCKET}" \
            -write "${TMP_DIR}" >"${TMP_DIR}/fetch-output.log" 2>"${fetch_error}"; then
            return 0
        fi
        sleep 2
    done

    echo "[authority-chain] could not fetch validation SVID from ${AUTHORITY_AGENT_SOCKET}" >&2
    echo "[authority-chain] expected SPIFFE ID: ${WORKLOAD_SPIFFE_ID}" >&2
    echo "[authority-chain] expected parent ID: ${PARENT_ID}" >&2
    echo "[authority-chain] expected selector: ${WORKLOAD_SELECTOR}" >&2
    if [[ -s "${fetch_error}" ]]; then
        echo "[authority-chain] last fetch error:" >&2
        cat "${fetch_error}" >&2
    fi
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
    # Shared with the first boot, which creates this entry before starting the adapter.
    PARENT_ID="$(
        WORKLOAD_SPIFFE_ID="${WORKLOAD_SPIFFE_ID}" \
        WORKLOAD_SELECTOR="${WORKLOAD_SELECTOR}" \
        "${AUTHORITY_DIR}/firstboot/ensure-validation-workload-entry.sh" | tail -n 1
    )"
    if [[ -z "${PARENT_ID}" ]]; then
        echo "[authority-chain] could not resolve the authority agent parent ID" >&2
        exit 1
    fi

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

    if [[ ! -f "${TMP_DIR}/cert-02.pem" ]]; then
        echo "[authority-chain] SVID chain has no intermediate CA." >&2
        echo "[authority-chain] This Authority signed the workload with its own root, so it is not nested." >&2
        echo "[authority-chain] Confirm UpstreamAuthority \"spire\" in ${AUTHORITY_SERVER_CONFIG} and the" >&2
        echo "[authority-chain] -downstream entry for ${AUTHORITY_SERVER_SPIFFE_ID} on the Trusted Root." >&2
        exit 1
    fi

    cat "${TMP_DIR}"/cert-0[2-9].pem > "${TMP_DIR}/intermediates.pem"
    openssl verify \
        -CAfile "${TMP_DIR}/bundle.0.pem" \
        -untrusted "${TMP_DIR}/intermediates.pem" \
        "${TMP_DIR}/cert-01.pem"

    if [[ ! -s "${TRUSTED_ROOT_BUNDLE_FILE}" ]]; then
        echo "[authority-chain] pinned trusted root bundle is missing: ${TRUSTED_ROOT_BUNDLE_FILE}" >&2
        echo "[authority-chain] Without it the chain can only be checked against the local bundle." >&2
        exit 1
    fi

    openssl verify \
        -CAfile "${TRUSTED_ROOT_BUNDLE_FILE}" \
        -untrusted "${TMP_DIR}/intermediates.pem" \
        "${TMP_DIR}/cert-01.pem"

    printf '[authority-chain] workload SVID: %s\n' "${WORKLOAD_SPIFFE_ID}"
    printf '[authority-chain] chain verification: OK\n'
    printf '[authority-chain] verified against pinned trusted root: %s\n' "${TRUSTED_ROOT_BUNDLE_FILE}"
    printf '[authority-chain] certificate subjects:\n'
    for cert in "${TMP_DIR}"/cert-*.pem; do
        openssl x509 -in "${cert}" -noout -subject -issuer
    done
}

main "$@"
