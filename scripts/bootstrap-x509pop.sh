#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly LOG_FILE="/var/log/spire-demo-bootstrap-x509pop.log"
readonly COMPLETE_FILE="/var/lib/spire-demo/bootstrap-x509pop-complete"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[bootstrap-x509pop] Iniciando bootstrap x509pop da instância..."
echo "[bootstrap-x509pop] Data: $(date --iso-8601=seconds)"
echo "[bootstrap-x509pop] Hostname: $(hostname)"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[bootstrap-x509pop] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

mkdir -p \
    /var/lib/spire-demo/evidence \
    /etc/spire \
    /opt/spire \
    /run/spire

echo "[bootstrap-x509pop] Validando material x509pop provisionado..."

for required_file in \
    "${SPIRE_X509POP_CA_BUNDLE}" \
    "${SPIRE_X509POP_AGENT_CERT}" \
    "${SPIRE_X509POP_AGENT_KEY}"; do

    if [[ ! -f "${required_file}" ]]; then
        echo "[bootstrap-x509pop] Arquivo x509pop ausente: ${required_file}" >&2
        exit 1
    fi
done

echo "[bootstrap-x509pop] Tornando scripts executáveis..."

chmod +x \
    "${REPOSITORY_DIR}/scripts/install-docker.sh" \
    "${REPOSITORY_DIR}/scripts/install-spire.sh" \
    "${REPOSITORY_DIR}/scripts/generate-evidence.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-server-x509pop.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-agent-x509pop.sh" \
    "${REPOSITORY_DIR}/scripts/run-spire-agent-x509pop.sh" \
    "${REPOSITORY_DIR}/scripts/configure-kv-workload.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-evidence-adapter.sh" \
    "${REPOSITORY_DIR}/scripts/configure-spire-chat-agent.sh"

echo "[bootstrap-x509pop] Instalando Docker..."

"${REPOSITORY_DIR}/scripts/install-docker.sh"

echo "[bootstrap-x509pop] Instalando SPIRE..."

"${REPOSITORY_DIR}/scripts/install-spire.sh"

echo "[bootstrap-x509pop] Configurando SPIRE Server com x509pop..."

"${REPOSITORY_DIR}/scripts/configure-spire-server-x509pop.sh"

echo "[bootstrap-x509pop] Configurando SPIRE Agent com x509pop..."

"${REPOSITORY_DIR}/scripts/configure-spire-agent-x509pop.sh"

echo "[bootstrap-x509pop] Configurando workload key-value store..."

"${REPOSITORY_DIR}/scripts/configure-kv-workload.sh"

echo "[bootstrap-x509pop] Configurando SPIRE MCP..."

"${REPOSITORY_DIR}/scripts/configure-spire-evidence-adapter.sh"

echo "[bootstrap-x509pop] Configurando agente grafico SPIRE..."

"${REPOSITORY_DIR}/scripts/configure-spire-chat-agent.sh"

echo "[bootstrap-x509pop] Gerando evidências..."

"${REPOSITORY_DIR}/scripts/generate-evidence.sh"

echo "[bootstrap-x509pop] Registrando conclusão..."

touch "${COMPLETE_FILE}"

echo "[bootstrap-x509pop] Bootstrap x509pop concluído com sucesso."
