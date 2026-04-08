#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command consul
require_command curl

ensure_runtime_dirs

readonly CONSUL_PID_FILE="${ROOT_DIR}/runtime/host-consul/consul.pid"
readonly CONSUL_LOG_FILE="${ROOT_DIR}/runtime/host-consul/consul.log"
readonly CONSUL_CONFIG_FILE="${ROOT_DIR}/generated/consul.host.hcl"

render_config_template "${ROOT_DIR}/config/consul/consul.hcl" "${CONSUL_CONFIG_FILE}"

if [[ -f "${CONSUL_PID_FILE}" ]]; then
  existing_pid="$(cat "${CONSUL_PID_FILE}")"
  if kill -0 "${existing_pid}" >/dev/null 2>&1; then
    wait_for_http "Host Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"
    exit 0
  fi
  rm -f "${CONSUL_PID_FILE}"
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
    consul agent -config-file="${CONSUL_CONFIG_FILE}" >"${CONSUL_LOG_FILE}" 2>&1 < /dev/null &
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
    consul agent -config-file="${CONSUL_CONFIG_FILE}" >"${CONSUL_LOG_FILE}" 2>&1 < /dev/null &
fi
echo "$!" > "${CONSUL_PID_FILE}"

wait_for_http "Host Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"
echo "host consul 已启动: ${CONSUL_HTTP_ADDR}"
