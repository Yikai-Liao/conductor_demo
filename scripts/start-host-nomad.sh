#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command nomad

ensure_runtime_dirs

foreground=0
if [[ "${1:-}" == "--foreground" ]]; then
  foreground=1
fi

readonly NOMAD_PID_FILE="${ROOT_DIR}/runtime/host-nomad/nomad.pid"
readonly NOMAD_LOG_FILE="${ROOT_DIR}/runtime/host-nomad/nomad.log"
readonly NOMAD_CONFIG_FILE="${ROOT_DIR}/generated/nomad.host.hcl"

render_config_template "${ROOT_DIR}/config/nomad/nomad.hcl" "${NOMAD_CONFIG_FILE}"

if [[ "${foreground}" == "1" ]]; then
  exec env \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    -u NO_PROXY \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u no_proxy \
    NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
    nomad agent -config="${NOMAD_CONFIG_FILE}"
fi

if [[ -f "${NOMAD_PID_FILE}" ]]; then
  existing_pid="$(cat "${NOMAD_PID_FILE}")"
  if kill -0 "${existing_pid}" >/dev/null 2>&1; then
    wait_for_http "Host Nomad API" "${NOMAD_ADDR}/v1/status/leader"
    exit 0
  fi
  rm -f "${NOMAD_PID_FILE}"
fi

if command -v setsid >/dev/null 2>&1; then
  setsid env \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    -u NO_PROXY \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u no_proxy \
    NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
    nomad agent -config="${NOMAD_CONFIG_FILE}" >"${NOMAD_LOG_FILE}" 2>&1 < /dev/null &
else
  nohup env \
    -u HTTP_PROXY \
    -u HTTPS_PROXY \
    -u ALL_PROXY \
    -u NO_PROXY \
    -u http_proxy \
    -u https_proxy \
    -u all_proxy \
    -u no_proxy \
    NOMAD_SKIP_DOCKER_IMAGE_WARN=1 \
    nomad agent -config="${NOMAD_CONFIG_FILE}" >"${NOMAD_LOG_FILE}" 2>&1 < /dev/null &
fi
echo "$!" > "${NOMAD_PID_FILE}"

wait_for_http "Host Nomad API" "${NOMAD_ADDR}/v1/status/leader"
echo "host nomad 已启动: ${NOMAD_ADDR}"
