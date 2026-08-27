#!/usr/bin/env bash
set -euo pipefail


AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
source "${AUTHORITY_DIR}/firstboot/nested-common.sh"

load_nested_env

RUNTIME_ENV="${RUNTIME_ENV:-${AUTHORITY_DIR}/config/runtime.env}"

load_runtime_env() {
    local line key value

    [[ -r "${RUNTIME_ENV}" ]] || return 0

    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "${key}" == "${line}" ]] && continue
        [[ -n "${!key:-}" ]] && continue
        printf -v "${key}" '%s' "${value}"
    done < "${RUNTIME_ENV}"
}

load_runtime_env

log() {
    printf '[a2a-worker-entries] %s\n' "$*"
}

server() {
    /opt/spire/bin/spire-server "$@" -socketPath "${AUTHORITY_SERVER_SOCKET}"
}

require_value() {
    local name="$1" value="$2"
    if [[ -z "${value}" ]]; then
        echo "[a2a-worker-entries] ${name} is empty. Set it in ${RUNTIME_ENV}." >&2
        return 1
    fi
}

resolve_workers_image_digest() {
    if [[ -n "${A2A_WORKERS_IMAGE_CONFIG_DIGEST:-}" ]]; then
        return 0
    fi

    require_value A2A_WORKERS_IMAGE "${A2A_WORKERS_IMAGE:-}"

    local digest
    if ! digest="$(docker image inspect --format '{{.Id}}' "${A2A_WORKERS_IMAGE}" 2>/dev/null)"; then
        echo "[a2a-worker-entries] A2A_WORKERS_IMAGE_CONFIG_DIGEST is empty and ${A2A_WORKERS_IMAGE} is not available locally." >&2
        echo "[a2a-worker-entries] Pull the image or set A2A_WORKERS_IMAGE_CONFIG_DIGEST in ${RUNTIME_ENV}." >&2
        return 1
    fi

    if [[ -z "${digest}" ]]; then
        echo "[a2a-worker-entries] docker returned an empty image config digest for ${A2A_WORKERS_IMAGE}." >&2
        echo "[a2a-worker-entries] Set A2A_WORKERS_IMAGE_CONFIG_DIGEST in ${RUNTIME_ENV}." >&2
        return 1
    fi

    A2A_WORKERS_IMAGE_CONFIG_DIGEST="${digest}"
    log "resolved worker image config digest: ${A2A_WORKERS_IMAGE_CONFIG_DIGEST}"
}

resolve_authority_agent() {
    local recorded tmp_dir agents_json resolved status
    recorded=""
    if [[ -s "${AUTHORITY_AGENT_NODE_ID_FILE}" ]]; then
        recorded="$(head -n 1 "${AUTHORITY_AGENT_NODE_ID_FILE}")"
    fi

    tmp_dir="$(mktemp -d /tmp/a2a-worker-entries.XXXXXX)"
    agents_json="${tmp_dir}/agents.json"
    server agent list -output json > "${agents_json}" 2>/dev/null || true

    set +e
    resolved="$(
        python3 "${AUTHORITY_DIR}/firstboot/resolve-upstream-agent.py" \
            --agents-json "${agents_json}" \
            --expected-node-id "${PARENT_ID:-${recorded}}" \
            --override-var PARENT_ID
    )"
    status=$?
    set -e

    rm -rf "${tmp_dir}"
    if [[ "${status}" -ne 0 ]]; then
        return "${status}"
    fi
    printf '%s\n' "${resolved}"
}

ensure_entry() {
    local parent_id="$1" spiffe_id="$2" uid="$3" label_value="$4"
    local selectors=(
        "unix:uid:${uid}"
        "docker:label:${A2A_WORKLOAD_LABEL_KEY}:${label_value}"
        "docker:image_config_digest:${A2A_WORKERS_IMAGE_CONFIG_DIGEST}"
    )

    local show_args=(-parentID "${parent_id}" -spiffeID "${spiffe_id}")
    local create_args=(-parentID "${parent_id}" -spiffeID "${spiffe_id}")
    local selector
    for selector in "${selectors[@]}"; do
        show_args+=(-selector "${selector}")
        create_args+=(-selector "${selector}")
    done

    if server entry show "${show_args[@]}" 2>/dev/null | grep -Fq "Entry ID"; then
        log "entry already exists for ${spiffe_id}"
        return 0
    fi

    log "creating entry ${spiffe_id} (parent ${parent_id})"
    for selector in "${selectors[@]}"; do
        log "  selector ${selector}"
    done
    server entry create "${create_args[@]}" >/dev/null
}

main() {
    local parent_id

    require_value A2A_WORKLOAD_LABEL_KEY "${A2A_WORKLOAD_LABEL_KEY:-}"
    resolve_workers_image_digest
    require_value A2A_WORKERS_IMAGE_CONFIG_DIGEST "${A2A_WORKERS_IMAGE_CONFIG_DIGEST:-}"

    parent_id="$(resolve_authority_agent)"
    if [[ -z "${parent_id}" ]]; then
        exit 1
    fi

    ensure_entry "${parent_id}" \
        "${A2A_WORKER_AUTOGEN_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/a2a/worker-autogen}" \
        "${A2A_WORKER_AUTOGEN_UID}" \
        "${A2A_WORKER_AUTOGEN_LABEL_VALUE}"

    ensure_entry "${parent_id}" \
        "${A2A_WORKER_CREWAI_SPIFFE_ID:-spiffe://${TRUST_DOMAIN}/a2a/worker-crewai}" \
        "${A2A_WORKER_CREWAI_UID}" \
        "${A2A_WORKER_CREWAI_LABEL_VALUE}"

    printf '%s\n' "${parent_id}"
}

main "$@"
