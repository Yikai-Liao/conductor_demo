#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command consul
require_command docker

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  echo "已生成 ${ROOT_DIR}/.env"
fi

if [[ ! -f "${ROOT_DIR}/docker/grafana/vendor/victoriametrics-logs-datasource.tar.gz" ]]; then
  "${ROOT_DIR}/docker/grafana/download-victorialogs-plugin.sh"
fi

ensure_runtime_dirs

"${SCRIPT_DIR}/start-host-consul.sh"
"${SCRIPT_DIR}/start-host-proxies.sh"

cd "${ROOT_DIR}"
docker compose up -d --build --remove-orphans --force-recreate

"${SCRIPT_DIR}/init-vault.sh"
wait_for_http "Gateway" "${GATEWAY_URL}/healthz"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"

"${SCRIPT_DIR}/register-infra-services.sh"
"${SCRIPT_DIR}/start-host-nomad.sh"
"${SCRIPT_DIR}/start-host-proxies.sh"

echo "基础设施已启动"
