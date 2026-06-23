#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly EVIDENCE_DIR="/var/lib/spire-demo/evidence"

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
    -socketPath /run/spire/server/private/api.sock \
    &> "${EVIDENCE_DIR}/spire-server-healthcheck.txt"

spire-server bundle show \
    -socketPath /run/spire/server/private/api.sock \
    &> "${EVIDENCE_DIR}/spire-server-bundle.txt"

if cmp -s "${REPOSITORY_DIR}/configs/server.conf" \
    /etc/spire/server.conf; then
    echo "match"
else
    echo "mismatch"
fi > "${EVIDENCE_DIR}/server-config-integrity.txt"

echo "[evidence] Calculando hashes dos artefatos..."

find "${REPOSITORY_DIR}" \
    -type f \
    ! -path "${REPOSITORY_DIR}/.git/*" \
    -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > "${EVIDENCE_DIR}/repository-files.sha256"

echo "[evidence] Evidências geradas em ${EVIDENCE_DIR}."