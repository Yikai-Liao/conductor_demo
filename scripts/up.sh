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

cd "${ROOT_DIR}"
docker compose up -d --build --remove-orphans

wait_for_http "Vault API" "${VAULT_ADDR}/v1/sys/health"
wait_for_http "Gateway" "${GATEWAY_URL}/healthz"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"

"${SCRIPT_DIR}/register-infra-services.sh"
"${SCRIPT_DIR}/start-host-nomad.sh"

echo "基础设施已启动"
