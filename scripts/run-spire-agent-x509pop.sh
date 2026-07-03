#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_FILE="/etc/spire/agent.conf"

echo "[spire-agent-x509pop] Iniciando com node attestation x509pop."

exec /opt/spire/bin/spire-agent run \
    -config "${CONFIG_FILE}"
