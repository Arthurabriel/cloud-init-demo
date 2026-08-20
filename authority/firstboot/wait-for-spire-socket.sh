#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 || "$#" -gt 4 ]]; then
    echo "Usage: wait-for-spire-socket.sh <description> <path> [attempts] [sleep_seconds]" >&2
    exit 2
fi

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
# shellcheck source=authority/firstboot/nested-common.sh
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

wait_for_path "$@"
