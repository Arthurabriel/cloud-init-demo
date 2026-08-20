#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env
require_var TRUSTED_SPIRE_SERVER

run_spire_agent_with_optional_join_token \
    "upstream-agent" \
    "${UPSTREAM_AGENT_CONFIG}" \
    "${UPSTREAM_AGENT_DATA_DIR}" \
    "${UPSTREAM_AGENT_JOIN_TOKEN_FILE}"
