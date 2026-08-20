#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

section() {
    printf '\n=== %s ===\n' "$1"
}

run_optional() {
    "$@" 2>&1 || true
}

section "OpenStack instance information"
run_optional python3 "${AUTHORITY_DIR}/firstboot/read-openstack-instance-uuid.py"
printf 'Config Drive note: metadata is configuration/context only; it is not cryptographic attestation.\n'

section "Cloud-init status"
if command -v cloud-init >/dev/null 2>&1; then
    run_optional cloud-init status --long
else
    printf 'cloud-init command not found\n'
fi

section "SPIRE version"
run_optional /opt/spire/bin/spire-server --version
run_optional /opt/spire/bin/spire-agent --version

section "Runtime configuration"
printf 'trust_domain=%s\n' "${TRUST_DOMAIN}"
printf 'trusted_root_endpoint=%s:%s\n' "${TRUSTED_SPIRE_SERVER:-<root-vm>}" "${TRUSTED_SPIRE_PORT}"
printf 'upstream_agent_socket=%s\n' "${UPSTREAM_AGENT_SOCKET}"
printf 'authority_server_socket=%s\n' "${AUTHORITY_SERVER_SOCKET}"
printf 'authority_agent_socket=%s\n' "${AUTHORITY_AGENT_SOCKET}"

section "Service status"
run_optional systemctl --no-pager -l status spire-agent-upstream.service
run_optional systemctl --no-pager -l status spire-server-authority.service
run_optional systemctl --no-pager -l status spire-agent-authority.service

section "Sockets"
ls -la "$(dirname "${UPSTREAM_AGENT_SOCKET}")" 2>/dev/null || true
ls -la "$(dirname "${AUTHORITY_SERVER_SOCKET}")" 2>/dev/null || true
ls -la "$(dirname "${AUTHORITY_AGENT_SOCKET}")" 2>/dev/null || true

section "Authority Server health"
run_optional /opt/spire/bin/spire-server healthcheck -socketPath "${AUTHORITY_SERVER_SOCKET}"

section "Registration and attestation status"
run_optional /opt/spire/bin/spire-server agent list -socketPath "${AUTHORITY_SERVER_SOCKET}"
run_optional /opt/spire/bin/spire-server entry show -socketPath "${AUTHORITY_SERVER_SOCKET}"

section "Trust bundle"
run_optional /opt/spire/bin/spire-server bundle show -socketPath "${AUTHORITY_SERVER_SOCKET}"

section "Certificate chain"
run_optional "${AUTHORITY_DIR}/firstboot/validate-authority-certificate-chain.sh"
