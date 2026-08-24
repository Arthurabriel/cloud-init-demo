#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

ROOT_SOCKET="${ROOT_SOCKET:-${TRUSTED_ROOT_SERVER_SOCKET}}"

echo "[export-trusted-root-bundle] reading bundle from ${ROOT_SOCKET}" >&2

/opt/spire/bin/spire-server bundle show \
    -socketPath "${ROOT_SOCKET}"
