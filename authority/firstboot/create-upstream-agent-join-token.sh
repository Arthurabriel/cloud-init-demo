#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

ROOT_SOCKET="${ROOT_SOCKET:-${TRUSTED_ROOT_SERVER_SOCKET}}"
UPSTREAM_AGENT_SPIFFE_ID="${UPSTREAM_AGENT_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/pgid/agent/openstack/authority-upstream}"
TOKEN_TTL="${TOKEN_TTL:-600}"

echo "[create-upstream-agent-join-token] creating token for ${UPSTREAM_AGENT_SPIFFE_ID}" >&2
echo "[create-upstream-agent-join-token] ttl=${TOKEN_TTL}s" >&2

/opt/spire/bin/spire-server token generate \
    -socketPath "${ROOT_SOCKET}" \
    -spiffeID "${UPSTREAM_AGENT_SPIFFE_ID}" \
    -ttl "${TOKEN_TTL}"
