#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly EVIDENCE_DIR="/var/lib/spire-demo/evidence"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[evidence] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

mkdir -p "${EVIDENCE_DIR}"

echo "[evidence] Registrando informações da instância..."

{
    echo "Bootstrap executado com sucesso."
    echo "Data: $(date --iso-8601=seconds)"
    echo "Hostname: $(hostname)"
    echo
    echo "Sistema operacional:"
    cat /etc/os-release
} > "${EVIDENCE_DIR}/environment.txt"

echo "[evidence] Registrando versões do runtime..."

docker --version \
    > "${EVIDENCE_DIR}/docker-version.txt"

docker compose version \
    > "${EVIDENCE_DIR}/docker-compose-version.txt"

containerd --version \
    > "${EVIDENCE_DIR}/containerd-version.txt"

systemctl is-active docker \
    > "${EVIDENCE_DIR}/docker-service-status.txt"

docker info \
    > "${EVIDENCE_DIR}/docker-info.txt"

echo "[evidence] Registrando imagem de validação..."

docker image inspect hello-world:latest \
    --format '{{index .RepoDigests 0}}' \
    > "${EVIDENCE_DIR}/hello-world-image-digest.txt"

echo "[evidence] Registrando repositório..."

git -C "${REPOSITORY_DIR}" remote get-url origin \
    > "${EVIDENCE_DIR}/repository-url.txt"

git -C "${REPOSITORY_DIR}" rev-parse HEAD \
    > "${EVIDENCE_DIR}/repository-commit.txt"

git -C "${REPOSITORY_DIR}" status --porcelain \
    > "${EVIDENCE_DIR}/repository-status.txt"


echo "[evidence] Registrando versões do SPIRE..."

spire-server --version \
    &> "${EVIDENCE_DIR}/spire-server-version.txt"

spire-agent --version \
    &> "${EVIDENCE_DIR}/spire-agent-version.txt"

sha256sum /opt/spire/bin/spire-server \
    > "${EVIDENCE_DIR}/spire-server.sha256"

sha256sum /opt/spire/bin/spire-agent \
    > "${EVIDENCE_DIR}/spire-agent.sha256"

readlink -f /usr/local/bin/spire-server \
    > "${EVIDENCE_DIR}/spire-server-link.txt"

readlink -f /usr/local/bin/spire-agent \
    > "${EVIDENCE_DIR}/spire-agent-link.txt"


echo "[evidence] Registrando configuração do SPIRE Server..."

sha256sum /etc/spire/server.conf \
    > "${EVIDENCE_DIR}/server.conf.sha256"

systemctl is-active spire-server \
    > "${EVIDENCE_DIR}/spire-server-service-status.txt"

systemctl is-enabled spire-server \
    > "${EVIDENCE_DIR}/spire-server-service-enabled.txt"

spire-server healthcheck \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    &> "${EVIDENCE_DIR}/spire-server-healthcheck.txt"

spire-server bundle show \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    &> "${EVIDENCE_DIR}/spire-server-bundle.txt"

if cmp -s "${REPOSITORY_DIR}/config/server.conf" \
    /etc/spire/server.conf; then
    echo "match"
else
    echo "mismatch"
fi > "${EVIDENCE_DIR}/server-config-integrity.txt"


echo "[evidence] Registrando configuração do SPIRE Agent..."

sha256sum /etc/spire/agent.conf \
    > "${EVIDENCE_DIR}/agent.conf.sha256"

if [[ ! -f "${REPOSITORY_DIR}/config/agent.conf" ]]; then
    echo "missing_source"
elif cmp -s \
    "${REPOSITORY_DIR}/config/agent.conf" \
    /etc/spire/agent.conf; then
    echo "match"
else
    echo "mismatch"
fi > "${EVIDENCE_DIR}/agent-config-integrity.txt"

systemctl is-active spire-agent \
    > "${EVIDENCE_DIR}/spire-agent-service-status.txt"

systemctl is-enabled spire-agent \
    > "${EVIDENCE_DIR}/spire-agent-service-enabled.txt"

spire-agent healthcheck \
    -socketPath "${SPIRE_AGENT_SOCKET}" \
    &> "${EVIDENCE_DIR}/spire-agent-healthcheck.txt"

stat "${SPIRE_AGENT_SOCKET}" \
    > "${EVIDENCE_DIR}/workload-api-socket.txt"

if [[ -e "${SPIRE_AGENT_JOIN_TOKEN_FILE}" ]]; then
    echo "present"
else
    echo "removed_after_attestation"
fi > "${EVIDENCE_DIR}/join-token-status.txt"

echo "[evidence] Registrando workload key-value store..."

systemctl is-active kv-store \
    > "${EVIDENCE_DIR}/kv-store-service-status.txt"

systemctl is-enabled kv-store \
    > "${EVIDENCE_DIR}/kv-store-service-enabled.txt"

docker inspect "${KV_CONTAINER_NAME}" \
    > "${EVIDENCE_DIR}/kv-store-container.json"

docker image inspect "${KEY_STORE_IMAGE}" \
    --format '{{index .RepoDigests 0}}' \
    > "${EVIDENCE_DIR}/kv-image-digest.txt"

docker image inspect "${KEY_STORE_IMAGE}" \
    --format '{{.Id}}' \
    > "${EVIDENCE_DIR}/kv-image-config-digest.txt"

docker ps \
    --filter "name=${KV_CONTAINER_NAME}" \
    > "${EVIDENCE_DIR}/kv-docker-ps.txt"

docker inspect "${KV_CONTAINER_NAME}" \
    --format '{{ index .Config.Labels "spire.workload" }}' \
    > "${EVIDENCE_DIR}/kv-store-spire-label.txt"

docker inspect "${KV_CONTAINER_NAME}" \
    --format '{{ index .Config.Labels "spire.app" }}' \
    > "${EVIDENCE_DIR}/kv-store-spire-app-label.txt"

docker inspect "${KV_CONTAINER_NAME}" \
    --format '{{ index .Config.Labels "spire.component" }}' \
    > "${EVIDENCE_DIR}/kv-store-spire-component-label.txt"

if [[ -f "${EVIDENCE_DIR}/kv-store/identity.json" ]]; then
    cp "${EVIDENCE_DIR}/kv-store/identity.json" \
        "${EVIDENCE_DIR}/kv-store-identity.json"
    echo "present"
else
    echo "missing"
fi > "${EVIDENCE_DIR}/kv-store-identity-status.txt"

curl \
    --fail \
    --silent \
    --show-error \
    http://127.0.0.1:8080/identity \
    > "${EVIDENCE_DIR}/kv-store-identity-response.json"

docker logs "${KV_CONTAINER_NAME}" \
    > "${EVIDENCE_DIR}/kv-store-logs.txt" \
    2>&1

spire-server entry show \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    -spiffeID "${KV_SPIFFE_ID}" \
    &> "${EVIDENCE_DIR}/kv-entry-show.txt"

if grep -Fq "${KV_SPIFFE_ID}" "${EVIDENCE_DIR}/kv-entry-show.txt"; then
    echo "present"
else
    echo "missing"
fi > "${EVIDENCE_DIR}/kv-store-registration-entry.txt"

echo "[evidence] Registrando agente grafico SPIRE..."

if [[ -f /etc/spire-demo/agent.env ]]; then
    echo "present"
else
    echo "missing"
fi > "${EVIDENCE_DIR}/spire-chat-agent-env-status.txt"

systemctl is-active spire-chat-agent \
    > "${EVIDENCE_DIR}/spire-chat-agent-service-status.txt" \
    2>&1 || true

systemctl is-enabled spire-chat-agent \
    > "${EVIDENCE_DIR}/spire-chat-agent-service-enabled.txt" \
    2>&1 || true

if curl \
    --silent \
    --show-error \
    --max-time 5 \
    --output /dev/null \
    --write-out "%{http_code}\n" \
    http://127.0.0.1:8081/ \
    > "${EVIDENCE_DIR}/spire-chat-agent-http-status.txt" \
    2>&1; then
    true
else
    echo "unavailable" >> "${EVIDENCE_DIR}/spire-chat-agent-http-status.txt"
fi


echo "[evidence] Calculando hashes dos artefatos..."

find "${REPOSITORY_DIR}" \
    -type f \
    ! -path "${REPOSITORY_DIR}/.git/*" \
    -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > "${EVIDENCE_DIR}/repository-files.sha256"

echo "[evidence] Evidências geradas em ${EVIDENCE_DIR}."
