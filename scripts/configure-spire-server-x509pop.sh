#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly CONFIG_SOURCE="${REPOSITORY_DIR}/config/server-x509pop.conf"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-server.service"
readonly X509POP_CA_SOURCE="${REPOSITORY_DIR}/config/x509pop/agent-ca.pem"

readonly CONFIG_DIR="/etc/spire"
readonly CONFIG_TARGET="${CONFIG_DIR}/server.conf"
readonly DATA_DIR="/var/lib/spire/server"
readonly SERVICE_TARGET="/etc/systemd/system/spire-server.service"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-server-x509pop] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

echo "[spire-server-x509pop] Configurando SPIRE Server com x509pop..."

for required_file in \
    "${CONFIG_SOURCE}" \
    "${SERVICE_SOURCE}"; do

    if [[ ! -f "${required_file}" ]]; then
        echo "[spire-server-x509pop] Arquivo ausente: ${required_file}" >&2
        exit 1
    fi
done

echo "[spire-server-x509pop] Criando usuário do serviço..."

if ! id spire-server >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir "${DATA_DIR}" \
        --shell /usr/sbin/nologin \
        spire-server
fi

echo "[spire-server-x509pop] Criando diretórios..."

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

install -d \
    -o root \
    -g spire-server \
    -m 0750 \
    "${SPIRE_X509POP_DIR}"

echo "[spire-server-x509pop] Instalando CA confiável dos Agents..."

if [[ -f "${X509POP_CA_SOURCE}" ]]; then
    install \
        -o root \
        -g spire-server \
        -m 0640 \
        "${X509POP_CA_SOURCE}" \
        "${SPIRE_X509POP_CA_BUNDLE}"
elif [[ -f "${SPIRE_X509POP_CA_BUNDLE}" ]]; then
    chown root:spire-server "${SPIRE_X509POP_CA_BUNDLE}"
    chmod 0640 "${SPIRE_X509POP_CA_BUNDLE}"
else
    echo "[spire-server-x509pop] CA x509pop ausente." >&2
    echo "[spire-server-x509pop] Provisione ${SPIRE_X509POP_CA_BUNDLE} ou ${X509POP_CA_SOURCE}." >&2
    exit 1
fi

echo "[spire-server-x509pop] Instalando configuração..."

install \
    -o root \
    -g spire-server \
    -m 0640 \
    "${CONFIG_SOURCE}" \
    "${CONFIG_TARGET}"

echo "[spire-server-x509pop] Instalando unidade systemd..."

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-server-x509pop] Habilitando e iniciando serviço..."

systemctl enable --now spire-server

echo "[spire-server-x509pop] Aguardando socket da API..."

for attempt in $(seq 1 30); do
    if [[ -S "${SPIRE_SERVER_SOCKET}" ]]; then
        echo "[spire-server-x509pop] Socket disponível."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-server-x509pop] Socket não foi criado." >&2
        systemctl status spire-server --no-pager || true
        journalctl -u spire-server --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-server-x509pop] Executando healthcheck..."

spire-server healthcheck \
    -socketPath "${SPIRE_SERVER_SOCKET}"

echo "[spire-server-x509pop] Configuração concluída."
