#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command docker
require_command socat

ensure_runtime_dirs

readonly PROXY_STATE_DIR="${ROOT_DIR}/runtime/host-proxies"
mkdir -p "${PROXY_STATE_DIR}"

gateway_addr="$(docker_host_gateway_addr)"
if [[ -z "${gateway_addr}" || "${gateway_addr}" == "null" ]]; then
  echo "无法解析 Docker host gateway 地址" >&2
  exit 1
fi

start_proxy() {
  local name="$1"
  local listen_port="$2"
  local target_port="$3"
  local probe_path="$4"
  local pid_file="${PROXY_STATE_DIR}/${name}.pid"
  local log_file="${PROXY_STATE_DIR}/${name}.log"

  if [[ -f "${pid_file}" ]]; then
    existing_pid="$(cat "${pid_file}")"
    if kill -0 "${existing_pid}" >/dev/null 2>&1; then
      curl -fsS "http://${gateway_addr}:${listen_port}${probe_path}" >/dev/null 2>&1 && return 0
      kill "${existing_pid}" >/dev/null 2>&1 || true
      rm -f "${pid_file}"
    else
      rm -f "${pid_file}"
    fi
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid socat \
      "TCP-LISTEN:${listen_port},bind=${gateway_addr},fork,reuseaddr" \
      "TCP:127.0.0.1:${target_port}" >"${log_file}" 2>&1 < /dev/null &
  else
    nohup socat \
      "TCP-LISTEN:${listen_port},bind=${gateway_addr},fork,reuseaddr" \
      "TCP:127.0.0.1:${target_port}" >"${log_file}" 2>&1 < /dev/null &
  fi
  echo "$!" > "${pid_file}"

  local attempt=1
  while ! curl -fsS "http://${gateway_addr}:${listen_port}${probe_path}" >/dev/null 2>&1; do
    if [[ "${attempt}" -ge 30 ]]; then
      echo "等待 ${name} proxy 就绪超时" >&2
      exit 1
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
}

start_proxy "consul" 8500 8500 "/v1/status/leader"
start_proxy "nomad" 4646 4646 "/v1/status/leader"

echo "host proxies 已启动:"
echo "  Consul proxy: ${gateway_addr}:8500 -> 127.0.0.1:8500"
echo "  Nomad proxy : ${gateway_addr}:4646 -> 127.0.0.1:4646"
