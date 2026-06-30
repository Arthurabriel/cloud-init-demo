#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly LOG_FILE="/var/log/spire-demo-bootstrap.log"
readonly COMPLETE_FILE="/var/lib/spire-demo/bootstrap-complete"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[bootstrap] Iniciando bootstrap da instância..."
echo "[bootstrap] Data: $(date --iso-8601=seconds)"
echo "[bootstrap] Hostname: $(hostname)"

mkdir -p \
    /var/lib/spire-demo/evidence \
    /etc/spire \
    /opt/spire \
    /run/spire

echo "[bootstrap] Tornando scripts executáveis..."

chmod +x \
    "${REPOSITORY_DIR}/scripts/install-docker.sh" \
    "${REPOSITORY_DIR}/scripts/install-spire.sh" \
    "${REPOSITORY_DIR}/scripts/generate-evidence.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-agent.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-server.sh" \
    "${REPOSITORY_DIR}/scripts/configure-kv-workload.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-mcp.sh"

echo "[bootstrap] Instalando Docker..."

"${REPOSITORY_DIR}/scripts/install-docker.sh"

echo "[bootstrap] Instalando SPIRE..."

"${REPOSITORY_DIR}/scripts/install-spire.sh"

echo "[bootstrap] Configurando SPIRE Server..."

"${REPOSITORY_DIR}/scripts/configure-spire-server.sh"

echo "[bootstrap] Configurando SPIRE Agent..."

"${REPOSITORY_DIR}/scripts/configure-spire-agent.sh"

echo "[bootstrap] Configurando workload key-value store..."

"${REPOSITORY_DIR}/scripts/configure-kv-workload.sh"

echo "[bootstrap] Configurando SPIRE MCP..."

"${REPOSITORY_DIR}/scripts/configure-spire-mcp.sh"

echo "[bootstrap] Gerando evidências..."

"${REPOSITORY_DIR}/scripts/generate-evidence.sh"

echo "[bootstrap] Registrando conclusão..."

touch "${COMPLETE_FILE}"

echo "[bootstrap] Bootstrap concluído com sucesso."