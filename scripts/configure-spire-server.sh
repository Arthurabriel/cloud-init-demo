#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly CONFIG_SOURCE="${REPOSITORY_DIR}/config/server.conf"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-server.service"

readonly CONFIG_DIR="/etc/spire"
readonly CONFIG_TARGET="${CONFIG_DIR}/server.conf"
readonly DATA_DIR="/var/lib/spire/server"
readonly SERVICE_TARGET="/etc/systemd/system/spire-server.service"

echo "[spire-server] Configurando SPIRE Server..."

if [[ ! -f "${CONFIG_SOURCE}" ]]; then
    echo "[spire-server] Configuração não encontrada: ${CONFIG_SOURCE}" >&2
    exit 1
fi

if [[ ! -f "${SERVICE_SOURCE}" ]]; then
    echo "[spire-server] Serviço não encontrado: ${SERVICE_SOURCE}" >&2
    exit 1
fi

echo "[spire-server] Criando usuário do serviço..."

if ! id spire-server >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir "${DATA_DIR}" \
        --shell /usr/sbin/nologin \
        spire-server
fi

echo "[spire-server] Criando diretórios..."

install -d \
    -o root \
    -g spire-server \
    -m 0750 \
    "${CONFIG_DIR}"

install -d \
    -o spire-server \
    -g spire-server \
    -m 0750 \
    "${DATA_DIR}"

echo "[spire-server] Instalando configuração..."

install \
    -o root \
    -g spire-server \
    -m 0640 \
    "${CONFIG_SOURCE}" \
    "${CONFIG_TARGET}"

echo "[spire-server] Instalando unidade systemd..."

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

echo "[spire-server] Recarregando systemd..."

systemctl daemon-reload

echo "[spire-server] Habilitando e iniciando serviço..."

systemctl enable --now spire-server

echo "[spire-server] Aguardando socket da API..."

for attempt in $(seq 1 30); do
    if [[ -S /run/spire/server/private/api.sock ]]; then
        echo "[spire-server] Socket disponível."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-server] Socket não foi criado." >&2
        systemctl status spire-server --no-pager || true
        journalctl -u spire-server --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-server] Executando healthcheck..."

spire-server healthcheck \
    -socketPath /run/spire/server/private/api.sock

echo "[spire-server] Configuração concluída."