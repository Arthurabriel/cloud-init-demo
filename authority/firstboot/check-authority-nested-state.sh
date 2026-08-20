#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

READY=true

section() {
    printf '\n=== %s ===\n' "$1"
}

status_line() {
    printf '%s: %s\n' "$1" "$2"
}

mark_not_ready() {
    READY=false
}

service_state() {
    local service="$1"
    if systemctl is-active --quiet "${service}"; then
        status_line service active
    else
        status_line service "not-active"
        mark_not_ready
    fi
}

socket_state() {
    local socket="$1"
    if [[ -S "${socket}" ]]; then
        status_line socket available
    else
        status_line socket missing
        mark_not_ready
    fi
}

section "Cloud-init"
if command -v cloud-init >/dev/null 2>&1; then
    status_line status "$(cloud-init status --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "unknown"))' 2>/dev/null || cloud-init status 2>/dev/null || true)"
else
    status_line status unavailable
fi

section "Upstream Agent"
service_state spire-agent-upstream.service
socket_state "${UPSTREAM_AGENT_SOCKET}"
status_line server "${TRUSTED_SPIRE_SERVER}:${TRUSTED_SPIRE_PORT}"

section "Authority Server"
service_state spire-server-authority.service
if /opt/spire/bin/spire-server healthcheck -socketPath "${AUTHORITY_SERVER_SOCKET}" >/dev/null 2>&1; then
    status_line health healthy
else
    status_line health unhealthy
    mark_not_ready
fi
if grep -q 'UpstreamAuthority "spire"' "${AUTHORITY_SERVER_CONFIG}" 2>/dev/null; then
    status_line "upstream authority" spire
else
    status_line "upstream authority" missing
    mark_not_ready
fi

section "Authority Agent"
service_state spire-agent-authority.service
socket_state "${AUTHORITY_AGENT_SOCKET}"
status_line server "127.0.0.1:${AUTHORITY_SPIRE_PORT}"

section "Nested SPIRE"
if /opt/spire/bin/spire-server bundle show -socketPath "${AUTHORITY_SERVER_SOCKET}" >/dev/null 2>&1; then
    status_line "intermediate CA" available
else
    status_line "intermediate CA" unavailable
    mark_not_ready
fi

section "Authority"
if [[ "${READY}" == "true" ]]; then
    status_line status READY
else
    status_line status "NOT READY"
    exit 1
fi
