#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

run_spire_agent_with_optional_join_token \
    "authority-agent" \
    "${AUTHORITY_AGENT_CONFIG}" \
    "${AUTHORITY_AGENT_DATA_DIR}" \
    "${AUTHORITY_AGENT_JOIN_TOKEN_FILE}"
