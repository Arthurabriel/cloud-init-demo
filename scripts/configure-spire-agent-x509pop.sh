#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"

readonly CONFIG_SOURCE="${REPOSITORY_DIR}/config/agent-x509pop.conf"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-agent.service"
readonly RUNNER_SOURCE="${REPOSITORY_DIR}/scripts/run-spire-agent-x509pop.sh"

readonly CONFIG_TARGET="/etc/spire/agent.conf"
readonly BUNDLE_TARGET="/etc/spire/agent-bundle.pem"
readonly SERVICE_TARGET="/etc/systemd/system/spire-agent.service"
readonly RUNNER_TARGET="/usr/local/sbin/run-spire-agent"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-agent-x509pop] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

echo "[spire-agent-x509pop] Configurando SPIRE Agent com x509pop..."

for required_file in \
    "${CONFIG_SOURCE}" \
    "${SERVICE_SOURCE}" \
    "${RUNNER_SOURCE}" \
    "${SPIRE_X509POP_AGENT_CERT}" \
    "${SPIRE_X509POP_AGENT_KEY}"; do

    if [[ ! -f "${required_file}" ]]; then
        echo "[spire-agent-x509pop] Arquivo ausente: ${required_file}" >&2
        exit 1
    fi
done

echo "[spire-agent-x509pop] Criando usuário..."

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

echo "[spire-agent-x509pop] Criando diretórios..."

install -d \
    -o root \
    -g root \
    -m 0755 \
    /etc/spire

install -d \
    -o root \
    -g spire-agent \
    -m 0750 \
    "${SPIRE_X509POP_DIR}"

install -d \
    -o spire-agent \
    -g spire-agent \
    -m 0750 \
    /var/lib/spire/agent

echo "[spire-agent-x509pop] Ajustando permissões do certificado de nó..."

chown root:spire-agent \
    "${SPIRE_X509POP_AGENT_CERT}" \
    "${SPIRE_X509POP_AGENT_KEY}"

chmod 0640 "${SPIRE_X509POP_AGENT_CERT}"
chmod 0640 "${SPIRE_X509POP_AGENT_KEY}"

echo "[spire-agent-x509pop] Instalando configuração..."

install \
    -o root \
    -g spire-agent \
    -m 0640 \
    "${CONFIG_SOURCE}" \
    "${CONFIG_TARGET}"

echo "[spire-agent-x509pop] Instalando wrapper de inicialização..."

install \
    -o root \
    -g root \
    -m 0755 \
    "${RUNNER_SOURCE}" \
    "${RUNNER_TARGET}"

echo "[spire-agent-x509pop] Exportando trust bundle do Server..."

spire-server bundle show \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    > "${BUNDLE_TARGET}"

chown root:spire-agent "${BUNDLE_TARGET}"
chmod 0640 "${BUNDLE_TARGET}"

echo "[spire-agent-x509pop] Validando agent.conf..."

spire-agent validate \
    -config "${CONFIG_TARGET}"

echo "[spire-agent-x509pop] Instalando serviço systemd..."

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-agent-x509pop] Habilitando e iniciando Agent..."

systemctl enable --now spire-agent

echo "[spire-agent-x509pop] Aguardando Workload API..."

for attempt in $(seq 1 30); do
    if [[ -S "${SPIRE_AGENT_SOCKET}" ]]; then
        echo "[spire-agent-x509pop] Workload API disponível."
        break
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-agent-x509pop] O socket não foi criado." >&2
        systemctl status spire-agent --no-pager || true
        journalctl -u spire-agent --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done

echo "[spire-agent-x509pop] Executando healthcheck..."

spire-agent healthcheck \
    -socketPath "${SPIRE_AGENT_SOCKET}"

echo "[spire-agent-x509pop] Confirmando atestação no Server..."

AGENT_LIST="$(
    spire-server agent list \
        -socketPath "${SPIRE_SERVER_SOCKET}"
)"

printf '%s\n' "${AGENT_LIST}"

if ! grep -Fq "${SPIRE_X509POP_AGENT_SPIFFE_ID_PREFIX}" <<< "${AGENT_LIST}"; then
    echo "[spire-agent-x509pop] Nenhum Agent atestado por x509pop foi encontrado." >&2
    exit 1
fi

if ! grep -Fq "Attestation type  : x509pop" <<< "${AGENT_LIST}"; then
    echo "[spire-agent-x509pop] O Agent encontrado não usa x509pop." >&2
    exit 1
fi

AGENT_SPIFFE_ID="$(
    printf '%s\n' "${AGENT_LIST}" |
        awk -F': ' '/^SPIFFE ID/ { print $2; exit }'
)"

if [[ -z "${AGENT_SPIFFE_ID}" ]]; then
    echo "[spire-agent-x509pop] Não foi possível extrair o SPIFFE ID do Agent." >&2
    exit 1
fi

printf '%s\n' "${AGENT_SPIFFE_ID}" \
    > "${SPIRE_AGENT_SPIFFE_ID_FILE}"

chown spire-agent:spire-agent \
    "${SPIRE_AGENT_SPIFFE_ID_FILE}"

chmod 0640 \
    "${SPIRE_AGENT_SPIFFE_ID_FILE}"

echo "[spire-agent-x509pop] Agent confirmado: ${AGENT_SPIFFE_ID}"
echo "[spire-agent-x509pop] Configuração concluída."
