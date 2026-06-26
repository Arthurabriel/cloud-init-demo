#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly VERSION_FILE="${REPOSITORY_DIR}/config/version.env"
readonly DOWNLOAD_DIR="/tmp/spire-download"

echo "[spire] Carregando versões..."

if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "[spire] Arquivo ${VERSION_FILE} não encontrado." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${VERSION_FILE}"

: "${SPIRE_VERSION:?SPIRE_VERSION não definido}"
: "${SPIRE_PLATFORM:?SPIRE_PLATFORM não definido}"
: "${SPIRE_INSTALL_DIR:?SPIRE_INSTALL_DIR não definido}"

readonly ARCHIVE_NAME="spire-${SPIRE_VERSION}-${SPIRE_PLATFORM}.tar.gz"
readonly CHECKSUM_NAME="spire-${SPIRE_VERSION}-${SPIRE_PLATFORM}_sha256sum.txt"

readonly RELEASE_BASE_URL="https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}"
readonly ARCHIVE_URL="${RELEASE_BASE_URL}/${ARCHIVE_NAME}"
readonly CHECKSUM_URL="${RELEASE_BASE_URL}/${CHECKSUM_NAME}"

echo "[spire] Versão: ${SPIRE_VERSION}"
echo "[spire] Plataforma: ${SPIRE_PLATFORM}"

rm -rf "${DOWNLOAD_DIR}"
mkdir -p "${DOWNLOAD_DIR}"

echo "[spire] Baixando pacote oficial..."

curl \
    --fail \
    --location \
    --retry 3 \
    --output "${DOWNLOAD_DIR}/${ARCHIVE_NAME}" \
    "${ARCHIVE_URL}"

echo "[spire] Baixando checksum oficial..."

curl \
    --fail \
    --location \
    --retry 3 \
    --output "${DOWNLOAD_DIR}/${CHECKSUM_NAME}" \
    "${CHECKSUM_URL}"

echo "[spire] Validando checksum do pacote..."

(
    cd "${DOWNLOAD_DIR}"
    sha256sum --check "${CHECKSUM_NAME}"
)

echo "[spire] Extraindo pacote..."

tar \
    --extract \
    --gzip \
    --file "${DOWNLOAD_DIR}/${ARCHIVE_NAME}" \
    --directory "${DOWNLOAD_DIR}"

readonly EXTRACTED_DIR="${DOWNLOAD_DIR}/spire-${SPIRE_VERSION}"

if [[ ! -x "${EXTRACTED_DIR}/bin/spire-server" ]]; then
    echo "[spire] Binário spire-server não encontrado." >&2
    exit 1
fi

if [[ ! -x "${EXTRACTED_DIR}/bin/spire-agent" ]]; then
    echo "[spire] Binário spire-agent não encontrado." >&2
    exit 1
fi

echo "[spire] Criando diretório de instalação..."

install -d \
    -m 0755 \
    "${SPIRE_INSTALL_DIR}/bin"

echo "[spire] Instalando binários..."

install \
    -m 0755 \
    "${EXTRACTED_DIR}/bin/spire-server" \
    "${SPIRE_INSTALL_DIR}/bin/spire-server"

install \
    -m 0755 \
    "${EXTRACTED_DIR}/bin/spire-agent" \
    "${SPIRE_INSTALL_DIR}/bin/spire-agent"

echo "[spire] Criando links em /usr/local/bin..."

ln -sfn \
    "${SPIRE_INSTALL_DIR}/bin/spire-server" \
    /usr/local/bin/spire-server

ln -sfn \
    "${SPIRE_INSTALL_DIR}/bin/spire-agent" \
    /usr/local/bin/spire-agent

echo "[spire] Validando binários instalados..."

spire-server --version
spire-agent --version

echo "[spire] Instalação concluída."
