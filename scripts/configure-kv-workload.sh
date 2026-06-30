#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY_DIR="/opt/spire-demo"
readonly RUNTIME_ENV="${REPOSITORY_DIR}/config/runtime.env"
readonly SERVICE_SOURCE="${REPOSITORY_DIR}/systemd/kv-store.service"
readonly SERVICE_TARGET="/etc/systemd/system/kv-store.service"

if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "[kv-store] Runtime env não encontrado: ${RUNTIME_ENV}" >&2
    exit 1
fi

source "${RUNTIME_ENV}"

echo "[kv-store] Configurando workload key-value store..."

if [[ ! -f "${SERVICE_SOURCE}" ]]; then
    echo "[kv-store] Serviço não encontrado: ${SERVICE_SOURCE}" >&2
    exit 1
fi

echo "[kv-store] Baixando imagem pública..."

docker pull "${KEY_STORE_IMAGE}"

install -d \
    -o root \
    -g root \
    -m 0755 \
    "${DEMO_EVIDENCE_DIR}" \
    "${KV_EVIDENCE_DIR}"

install \
    -o root \
    -g root \
    -m 0644 \
    "${SERVICE_SOURCE}" \
    "${SERVICE_TARGET}"

systemctl daemon-reload

echo "[kv-store] Validando saúde do SPIRE Agent..."

spire-agent healthcheck \
    -socketPath "${SPIRE_AGENT_SOCKET}"

if [[ ! -s "${SPIRE_AGENT_SPIFFE_ID_FILE}" ]]; then
    echo "[kv-store] SPIFFE ID do Agent não encontrado: ${SPIRE_AGENT_SPIFFE_ID_FILE}" >&2
    exit 1
fi

AGENT_SPIFFE_ID="$(< "${SPIRE_AGENT_SPIFFE_ID_FILE}")"

echo "[kv-store] Validando ParentID do Agent..."

AGENT_LIST="$(
    spire-server agent list \
        -socketPath "${SPIRE_SERVER_SOCKET}"
)"

if ! grep -Fq "${AGENT_SPIFFE_ID}" <<< "${AGENT_LIST}"; then
    echo "[kv-store] Agent ParentID não encontrado no SPIRE Server: ${AGENT_SPIFFE_ID}" >&2
    printf '%s\n' "${AGENT_LIST}" >&2
    exit 1
fi

echo "[kv-store] Registrando workload no SPIRE Server..."

ENTRY_OUTPUT="$(
    spire-server entry show \
        -socketPath "${SPIRE_SERVER_SOCKET}" \
        -spiffeID "${KV_SPIFFE_ID}" \
        2>/dev/null || true
)"

if grep -Fq "${KV_SPIFFE_ID}" <<< "${ENTRY_OUTPUT}"; then
    echo "[kv-store] Registration entry já existe."
    ENTRY_ID="$(
        printf '%s\n' "${ENTRY_OUTPUT}" |
            awk -F': ' '/^Entry ID/ { print $2; exit }'
    )"
else
    KV_SELECTORS=(
        "${KV_SELECTOR_1}"
        "${KV_SELECTOR_2}"
        "${KV_SELECTOR_3}"
        "${KV_SELECTOR_4}"
    )

    ENTRY_CREATE_ARGS=(
        -socketPath "${SPIRE_SERVER_SOCKET}"
        -spiffeID "${KV_SPIFFE_ID}"
        -parentID "${AGENT_SPIFFE_ID}"
    )

    for selector in "${KV_SELECTORS[@]}"; do
        ENTRY_CREATE_ARGS+=(-selector "${selector}")
    done

    CREATE_OUTPUT="$(
        spire-server entry create \
            "${ENTRY_CREATE_ARGS[@]}"
    )"

    ENTRY_ID="$(
        printf '%s\n' "${CREATE_OUTPUT}" |
            awk -F': ' '/^Entry ID/ { print $2; exit }'
    )"
fi

if [[ -z "${ENTRY_ID}" ]]; then
    echo "[kv-store] Não foi possível extrair o Entry ID da workload." >&2
    exit 1
fi

printf '%s\n' "${ENTRY_ID}" \
    > "${DEMO_EVIDENCE_DIR}/kv-entry-id.txt"

echo "[kv-store] Validando Registration Entry..."

spire-server entry show \
    -socketPath "${SPIRE_SERVER_SOCKET}" \
    -spiffeID "${KV_SPIFFE_ID}" \
    &> "${DEMO_EVIDENCE_DIR}/kv-entry-show.txt"

if ! grep -Fq "${KV_SPIFFE_ID}" "${DEMO_EVIDENCE_DIR}/kv-entry-show.txt"; then
    echo "[kv-store] Registration Entry não encontrada após create/show." >&2
    cat "${DEMO_EVIDENCE_DIR}/kv-entry-show.txt" >&2
    exit 1
fi

echo "[kv-store] Habilitando e iniciando serviço..."

systemctl enable kv-store
systemctl restart kv-store

echo "[kv-store] Aguardando container e identidade SPIFFE..."

for attempt in $(seq 1 30); do
    if docker inspect "${KV_CONTAINER_NAME}" >/dev/null 2>&1; then
        if docker exec "${KV_CONTAINER_NAME}" \
            /bin/sh -c "wget -q -O - http://127.0.0.1:8080/identity | grep -Fq '${KV_SPIFFE_ID}'"; then
            echo "[kv-store] Workload em execução com identidade disponível."
            break
        fi
    fi

    if [[ "${attempt}" -eq 30 ]]; then
        echo "[kv-store] Workload não ficou disponível." >&2
        systemctl status kv-store --no-pager || true
        journalctl -u kv-store --no-pager -n 100 || true
        docker logs "${KV_CONTAINER_NAME}" || true
        exit 1
    fi

    sleep 2
done

echo "[kv-store] Workload configurada."
