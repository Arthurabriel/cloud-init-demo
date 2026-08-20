#!/usr/bin/env bash
set -euo pipefail

AUTHORITY_DIR="${AUTHORITY_DIR:-/opt/spire-demo/authority}"
NESTED_DEFAULTS_ENV="${AUTHORITY_DIR}/config/nested-defaults.env"
NESTED_INSTANCE_ENV="${NESTED_INSTANCE_ENV:-/etc/pgid-authority/nested.env}"

load_nested_env() {
    if [[ ! -f "${NESTED_DEFAULTS_ENV}" ]]; then
        echo "[nested-common] defaults file not found: ${NESTED_DEFAULTS_ENV}" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${NESTED_DEFAULTS_ENV}"

    if [[ -f "${NESTED_INSTANCE_ENV}" ]]; then
        # shellcheck disable=SC1090
        source "${NESTED_INSTANCE_ENV}"
    fi

    if [[ -z "${AUTHORITY_SERVER_SPIFFE_ID:-}" ]]; then
        AUTHORITY_SERVER_SPIFFE_ID="spiffe://${TRUST_DOMAIN}/authority/server"
    fi
}

log_nested() {
    printf '[nested-spire] %s\n' "$*"
}

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "[nested-spire] required variable is empty: ${name}" >&2
        exit 1
    fi
}

install_runtime_dirs() {
    install -d -o root -g root -m 0755 /etc/pgid-authority /etc/spire
    install -d -o root -g root -m 0755 "${NESTED_FIRSTBOOT_STATE_DIR}" "${NESTED_FIRSTBOOT_LOG_DIR}"

    install -d -o spire-server -g spire-server -m 0750 \
        "${TRUSTED_ROOT_SERVER_DATA_DIR}" \
        "${AUTHORITY_SERVER_DATA_DIR}"

    install -d -o spire-agent -g spire-agent -m 0750 \
        "${UPSTREAM_AGENT_DATA_DIR}" \
        "${AUTHORITY_AGENT_DATA_DIR}"

    install -d -o root -g spire-server -m 0750 "$(dirname "${TRUSTED_ROOT_SERVER_CONFIG}")"
    install -d -o root -g spire-server -m 0750 "$(dirname "${AUTHORITY_SERVER_CONFIG}")"
    install -d -o root -g spire-agent -m 0750 "$(dirname "${UPSTREAM_AGENT_CONFIG}")"
    install -d -o root -g spire-agent -m 0750 "$(dirname "${AUTHORITY_AGENT_CONFIG}")"
}

render_template() {
    local source="$1"
    local target="$2"
    local owner_group="$3"
    local mode="$4"
    local tmp

    if [[ ! -f "${source}" ]]; then
        echo "[nested-spire] template not found: ${source}" >&2
        exit 1
    fi

    tmp="$(mktemp)"
    cp "${source}" "${tmp}"

    local replacements=(
        TRUST_DOMAIN
        ROOT_SPIRE_BIND_ADDRESS
        ROOT_SPIRE_PORT
        TRUSTED_SPIRE_SERVER
        TRUSTED_SPIRE_PORT
        AUTHORITY_SPIRE_BIND_ADDRESS
        AUTHORITY_SPIRE_PORT
        TRUSTED_ROOT_SERVER_SOCKET
        TRUSTED_ROOT_SERVER_DATA_DIR
        UPSTREAM_AGENT_SOCKET
        UPSTREAM_AGENT_DATA_DIR
        AUTHORITY_SERVER_SOCKET
        AUTHORITY_SERVER_DATA_DIR
        AUTHORITY_AGENT_SOCKET
        AUTHORITY_AGENT_DATA_DIR
    )

    local name value escaped
    for name in "${replacements[@]}"; do
        value="${!name:-}"
        escaped="${value//\\/\\\\}"
        escaped="${escaped//&/\\&}"
        sed -i "s|@${name}@|${escaped}|g" "${tmp}"
    done

    install -o "${owner_group%:*}" -g "${owner_group#*:}" -m "${mode}" "${tmp}" "${target}"
    rm -f "${tmp}"
}

wait_for_path() {
    local description="$1"
    local path="$2"
    local attempts="${3:-60}"
    local sleep_seconds="${4:-2}"

    for attempt in $(seq 1 "${attempts}"); do
        if [[ -S "${path}" || -e "${path}" ]]; then
            log_nested "${description} available: ${path}"
            return 0
        fi

        if [[ "${attempt}" -eq "${attempts}" ]]; then
            echo "[nested-spire] timeout waiting for ${description}: ${path}" >&2
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

wait_for_service_active() {
    local service="$1"
    local attempts="${2:-60}"
    local sleep_seconds="${3:-2}"

    for attempt in $(seq 1 "${attempts}"); do
        if systemctl is-active --quiet "${service}"; then
            log_nested "service active: ${service}"
            return 0
        fi
        if [[ "${attempt}" -eq "${attempts}" ]]; then
            systemctl status "${service}" --no-pager -l >&2 || true
            journalctl -u "${service}" --no-pager -n 120 >&2 || true
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

wait_for_spire_server_health() {
    local description="$1"
    local socket="$2"
    local attempts="${3:-60}"
    local sleep_seconds="${4:-2}"

    for attempt in $(seq 1 "${attempts}"); do
        if /opt/spire/bin/spire-server healthcheck -socketPath "${socket}" >/dev/null 2>&1; then
            log_nested "${description} healthy"
            return 0
        fi
        if [[ "${attempt}" -eq "${attempts}" ]]; then
            echo "[nested-spire] timeout waiting for ${description} healthcheck" >&2
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

wait_for_spire_agent_health() {
    local description="$1"
    local socket="$2"
    local attempts="${3:-60}"
    local sleep_seconds="${4:-2}"

    for attempt in $(seq 1 "${attempts}"); do
        if /opt/spire/bin/spire-agent healthcheck -socketPath "${socket}" >/dev/null 2>&1; then
            log_nested "${description} healthy"
            return 0
        fi
        if [[ "${attempt}" -eq "${attempts}" ]]; then
            echo "[nested-spire] timeout waiting for ${description} healthcheck" >&2
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

agent_data_has_state() {
    local data_dir="$1"
    find "${data_dir}" \
        -mindepth 1 \
        ! -name join-token \
        -print \
        -quit 2>/dev/null | grep -q .
}

run_spire_agent_with_optional_join_token() {
    local label="$1"
    local config="$2"
    local data_dir="$3"
    local join_token_file="$4"

    if agent_data_has_state "${data_dir}"; then
        log_nested "${label}: starting with persisted identity"
        exec /opt/spire/bin/spire-agent run -config "${config}"
    fi

    if [[ ! -s "${join_token_file}" ]]; then
        echo "[nested-spire] ${label}: no persisted identity and join token file is missing: ${join_token_file}" >&2
        echo "[nested-spire] ${label}: create/provide a node attestation token or switch to the configured attestor before starting." >&2
        exit 1
    fi

    log_nested "${label}: first attestation with join token"
    exec /opt/spire/bin/spire-agent run \
        -config "${config}" \
        -joinToken "$(cat "${join_token_file}")"
}
