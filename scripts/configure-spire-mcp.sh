#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-mcp.service"
readonly SERVICE_TARGET="/etc/systemd/system/spire-mcp.service"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-mcp] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

echo "[spire-mcp] Configurando MCP do SPIRE..."

if [[ ! -f "${SERVICE_SOURCE}" ]]; then
    echo "[spire-mcp] Serviço não encontrado: ${SERVICE_SOURCE}" >&2
    exit 1
fi

echo "[spire-mcp] Baixando imagem pública..."

docker pull "${SPIRE_MCP_IMAGE}"

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-mcp] Habilitando e iniciando serviço..."

systemctl enable --now spire-mcp

echo "[spire-mcp] Aguardando container..."

for attempt in $(seq 1 30); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${SPIRE_MCP_CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
        echo "[spire-mcp] Container em execução."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-mcp] Container não ficou disponível." >&2
        systemctl status spire-mcp --no-pager || true
        journalctl -u spire-mcp --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-mcp] MCP configurado em http://127.0.0.1:8000/mcp."
