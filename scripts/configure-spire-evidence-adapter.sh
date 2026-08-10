#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-evidence-adapter.service"
readonly SERVICE_TARGET="/etc/systemd/system/spire-evidence-adapter.service"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-evidence-adapter] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

echo "[spire-evidence-adapter] Configurando SPIRE Evidence Adapter..."

if [[ ! -f "${SERVICE_SOURCE}" ]]; then
    echo "[spire-evidence-adapter] Serviço não encontrado: ${SERVICE_SOURCE}" >&2
    exit 1
fi

echo "[spire-evidence-adapter] Baixando imagem pública..."

if ! docker pull "${SPIRE_EVIDENCE_ADAPTER_IMAGE}"; then
    cat >&2 <<EOF
[spire-evidence-adapter] Nao foi possivel baixar a imagem:
[spire-evidence-adapter]   ${SPIRE_EVIDENCE_ADAPTER_IMAGE}
[spire-evidence-adapter]
[spire-evidence-adapter] Publique essa imagem em um registry acessivel pela VM
[spire-evidence-adapter] ou ajuste SPIRE_EVIDENCE_ADAPTER_IMAGE em:
[spire-evidence-adapter]   ${RUNTIME_ENV}
EOF
    exit 1
fi

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-evidence-adapter] Habilitando e iniciando serviço..."

systemctl enable --now spire-evidence-adapter

echo "[spire-evidence-adapter] Aguardando container..."

for attempt in $(seq 1 30); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "${SPIRE_EVIDENCE_ADAPTER_CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]; then
        echo "[spire-evidence-adapter] Container em execução."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-evidence-adapter] Container não ficou disponível." >&2
        systemctl status spire-evidence-adapter --no-pager || true
        journalctl -u spire-evidence-adapter --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-evidence-adapter] SPIRE Evidence Adapter configurado em http://127.0.0.1:8000/mcp."
