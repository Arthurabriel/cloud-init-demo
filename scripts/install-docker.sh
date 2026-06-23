#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[docker] Removendo pacotes conflitantes..."

CONFLICTING_PACKAGES=(
    docker.io
    docker-compose
    docker-compose-v2
    docker-doc
    podman-docker
    containerd
    runc
)

for package in "${CONFLICTING_PACKAGES[@]}"; do
apt-get remove -y "${package}" 2>/dev/null || true
done

echo "[docker] Criando diretório de chaves..."

install -m 0755 -d /etc/apt/keyrings

echo "[docker] Baixando chave oficial..."

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
-o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

echo "[docker] Adicionando repositório oficial..."

. /etc/os-release

ARCHITECTURE="$(dpkg --print-architecture)"

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${ARCHITECTURE}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

echo "[docker] Instalando Docker Engine..."

apt-get install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

echo "[docker] Ativando o serviço..."

systemctl enable --now docker

echo "[docker] Aguardando o daemon..."

for attempt in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        echo "[docker] Daemon disponível."
        break
    fi

    if [ "${attempt}" -eq 30 ]; then
        echo "[docker] O daemon não ficou disponível." >&2
        exit 1
    fi

    sleep 2
done

echo "[docker] Adicionando ubuntu ao grupo docker..."

if id ubuntu >/dev/null 2>&1; then
usermod -aG docker ubuntu
fi

echo "[docker] Executando container de validação..."

docker run --rm hello-world