#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command docker
require_command jq

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  echo "已生成 ${ROOT_DIR}/.env"
fi

if [[ ! -f "${ROOT_DIR}/docker/grafana/vendor/victoriametrics-logs-datasource.tar.gz" ]]; then
  "${ROOT_DIR}/docker/grafana/download-victorialogs-plugin.sh"
fi

cd "${ROOT_DIR}"
docker compose up -d --build --remove-orphans

wait_for_http "Conductor metadata" "${CONDUCTOR_SERVER_URL}/metadata/taskdefs"
wait_for_http "Conductor UI" "${CONDUCTOR_UI_URL}"
wait_for_http "func1 worker" "http://localhost:8091/healthz"
wait_for_http "func2 worker" "http://localhost:8092/healthz"
wait_for_http "review service" "${REVIEW_SERVICE_URL}/healthz"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"
wait_for_http "VictoriaMetrics" "${VICTORIA_METRICS_URL}/health"
wait_for_http "VictoriaLogs" "${VICTORIA_LOGS_URL}/health"

"${SCRIPT_DIR}/register-defs.sh"

echo "启动完成:"
echo "  Conductor API: ${CONDUCTOR_SERVER_URL}"
echo "  Conductor UI : ${CONDUCTOR_UI_URL}"
echo "  Review API   : ${REVIEW_SERVICE_URL}"
echo "  Grafana      : ${GRAFANA_URL}"
