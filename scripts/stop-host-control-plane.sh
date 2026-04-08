#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env

stop_pid_file() {
  local pid_file="$1"
  local name="$2"

  if [[ ! -f "${pid_file}" ]]; then
    return 0
  fi

  local pid
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${pid_file}"
  echo "已停止 ${name}"
}

stop_pid_file "${ROOT_DIR}/runtime/host-nomad/nomad.pid" "host nomad"
stop_pid_file "${ROOT_DIR}/runtime/host-consul/consul.pid" "host consul"
