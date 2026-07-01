#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/spire-chat-agent.service"
readonly SERVICE_TARGET="/etc/systemd/system/spire-chat-agent.service"
readonly CHAT_AGENT_ENV_FILE="/etc/spire-demo/agent.env"

echo "[spire-chat-agent] Configurando UI grafica do agente..."

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[spire-chat-agent] Runtime env nao encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

if [[ ! -f "${SERVICE_SOURCE}" ]]; then
    echo "[spire-chat-agent] Servico nao encontrado: ${SERVICE_SOURCE}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

mkdir -p /etc/spire-demo

if [[ ! -f "${CHAT_AGENT_ENV_FILE}" ]]; then
    cat >&2 <<EOF
[spire-chat-agent] Agent env ausente: ${CHAT_AGENT_ENV_FILE}
[spire-chat-agent] Criando template. A UI sera iniciada, mas o chat so respondera via Gemini apos preencher:
[spire-chat-agent]   GEMINI_API_KEY=<operator-provided-key>
EOF

    install -o root -g root -m 0600 /dev/null "${CHAT_AGENT_ENV_FILE}"
    {
        echo "# Preencha esta chave e reinicie: systemctl restart spire-chat-agent"
        echo "GEMINI_API_KEY="
    } > "${CHAT_AGENT_ENV_FILE}"
fi

echo "[spire-chat-agent] Baixando imagem publica..."

docker pull "${SPIRE_CHAT_AGENT_IMAGE}"

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[spire-chat-agent] Habilitando servico..."

systemctl enable spire-chat-agent

echo "[spire-chat-agent] Iniciando servico..."

systemctl start spire-chat-agent

echo "[spire-chat-agent] Aguardando UI em http://127.0.0.1:8081/..."

for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8081/ >/dev/null; then
        echo "[spire-chat-agent] UI disponivel em http://0.0.0.0:8081/."
        exit 0
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[spire-chat-agent] UI nao ficou disponivel." >&2
        systemctl status spire-chat-agent --no-pager || true
        journalctl -u spire-chat-agent --no-pager -n 100 || true
        exit 1
    fi

    sleep 2
done
