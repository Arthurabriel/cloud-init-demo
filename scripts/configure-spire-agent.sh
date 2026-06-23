#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"

readonly CONFIG_SOURCE="${REPOSITORY_DIR}/config/agent.conf"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-agent.service"
readonly RUNNER_SOURCE="${REPOSITORY_DIR}/scripts/run-spire-agent.sh"

readonly CONFIG_TARGET="/etc/spire/agent.conf"
readonly BUNDLE_TARGET="/etc/spire/agent-bundle.pem"
readonly SERVICE_TARGET="/etc/systemd/system/spire-agent.service"
readonly RUNNER_TARGET="/usr/local/sbin/run-spire-agent"

readonly SERVER_SOCKET="/run/spire/server/private/api.sock"
readonly AGENT_SOCKET="/run/spire/agent/public/api.sock"
readonly JOIN_TOKEN_FILE="/run/spire/agent/join-token"

readonly AGENT_SPIFFE_ID="spiffe://example.org/host/spire-demo"

echo "[spire-agent] Configurando SPIRE Agent..."

for required_file in \
    "${CONFIG_SOURCE}" \
    "${SERVICE_SOURCE}" \
    "${RUNNER_SOURCE}"; do

    if [[ ! -f "${required_file}" ]]; then
        echo "[spire-agent] Arquivo ausente: ${required_file}" >&2
        exit 1
    fi
done

echo "[spire-agent] Criando usuário..."

if ! id spire-agent >/dev/null 2>&1; then
    useradd \
        --system \
        --home-dir /var/lib/spire/agent \
        --shell /usr/sbin/nologin \
        spire-agent
fi

if getent group docker >/dev/null 2>&1; then
    usermod -aG docker spire-agent
fi

echo "[spire-agent] Criando diretórios..."

install -d \
    -o root \
    -g spire-agent \
    -m 0750 \
    /etc/spire

install -d \
    -o spire-agent \
    -g spire-agent \
    -m 0750 \
    /var/lib/spire/agent

install -d \
    -o spire-agent \
    -g spire-agent \
    -m 0750 \
    /run/spire/agent/public

echo "[spire-agent] Instalando configuração..."

install \
    -o root \
    -g spire-agent \
    -m 0640 \
    "${CONFIG_SOURCE}" \
    "${CONFIG_TARGET}"

echo "[spire-agent] Instalando wrapper de inicialização..."

install \
    -o root \
    -g root \
    -m 0755 \
    "${RUNNER_SOURCE}" \
    "${RUNNER_TARGET}"

echo "[spire-agent] Exportando trust bundle do Server..."

spire-server bundle show \
    -socketPath "${SERVER_SOCKET}" \
    > "${BUNDLE_TARGET}"

chown root:spire-agent "${BUNDLE_TARGET}"
chmod 0640 "${BUNDLE_TARGET}"

echo "[spire-agent] Validando agent.conf..."

spire-agent validate \
    -config "${CONFIG_TARGET}"

echo "[spire-agent] Gerando join token..."

TOKEN_OUTPUT="$(
    spire-server token generate \
        -socketPath "${SERVER_SOCKET}" \
        -spiffeID "${AGENT_SPIFFE_ID}" \
        -ttl 600
)"

JOIN_TOKEN="$(
    printf '%s\n' "${TOKEN_OUTPUT}" |
        awk '$1 == "Token:" { print $2 }'
)"

if [[ -z "${JOIN_TOKEN}" ]]; then
    echo "[spire-agent] Não foi possível extrair o join token." >&2
    printf '%s\n' "${TOKEN_OUTPUT}" >&2
    exit 1
fi

install \
    -o spire-agent \
    -g spire-agent \
    -m 0600 \
    /dev/null \
    "${JOIN_TOKEN_FILE}"

printf '%s\n' "${JOIN_TOKEN}" > "${JOIN_TOKEN_FILE}"

echo "[spire-agent] Instalando serviço systemd..."

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-agent] Habilitando e iniciando Agent..."

systemctl enable --now spire-agent

echo "[spire-agent] Aguardando Workload API..."

for attempt in $(seq 1 30); do
    if [[ -S "${AGENT_SOCKET}" ]]; then
        echo "[spire-agent] Workload API disponível."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-agent] O socket não foi criado." >&2
        systemctl status spire-agent --no-pager || true
        journalctl -u spire-agent --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-agent] Executando healthcheck..."

spire-agent healthcheck \
    -socketPath "${AGENT_SOCKET}"

echo "[spire-agent] Confirmando atestação no Server..."

AGENT_LIST="$(
    spire-server agent list \
        -socketPath "${SERVER_SOCKET}"
)"

printf '%s\n' "${AGENT_LIST}"

if ! grep -Fq "${AGENT_SPIFFE_ID}" <<< "${AGENT_LIST}"; then
    echo "[spire-agent] Agent esperado não aparece no Server." >&2
    exit 1
fi

echo "[spire-agent] Removendo token já utilizado..."

rm -f "${JOIN_TOKEN_FILE}"

echo "[spire-agent] Configuração concluída."