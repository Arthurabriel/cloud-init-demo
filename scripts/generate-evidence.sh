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

echo "[evidence] Calculando hashes dos artefatos..."

find "${REPOSITORY_DIR}" \
    -type f \
    ! -path "${REPOSITORY_DIR}/.git/*" \
    -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > "${EVIDENCE_DIR}/repository-files.sha256"

echo "[evidence] Evidências geradas em ${EVIDENCE_DIR}."