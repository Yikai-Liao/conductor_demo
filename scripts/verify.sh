#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command docker
require_command jq

wait_for_http "Gateway" "${GATEWAY_URL}/healthz"
wait_for_http "Conductor metadata" "${CONDUCTOR_SERVER_URL}/metadata/taskdefs"
wait_for_http "Conductor UI" "${CONDUCTOR_UI_URL}"
wait_for_http "review service" "${REVIEW_SERVICE_URL}/healthz"
wait_for_http "Nomad UI" "${NOMAD_ADDR}/v1/status/leader"
wait_for_http "Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"
wait_for_http "Vault API" "${VAULT_ADDR}/v1/sys/health"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"

toolbox_exec "./scripts/register-defs.sh" >/dev/null
"${SCRIPT_DIR}/run-one.sh" --x 1 --auto-review --wait >/tmp/conductor-run-one.json

sleep 6
toolbox_exec "./scripts/verify-internal.sh" >/dev/null

wait_for_contains \
  "Grafana VictoriaMetrics datasource" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:${GRAFANA_PORT:-13000}/api/datasources/uid/victoria-metrics" \
  "VictoriaMetrics"
wait_for_contains \
  "Grafana VictoriaLogs datasource" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:${GRAFANA_PORT:-13000}/api/datasources/uid/victoria-logs" \
  "VictoriaLogs"
wait_for_contains \
  "Grafana dashboard" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:${GRAFANA_PORT:-13000}/api/dashboards/uid/conductor-human-review-demo" \
  "\"uid\":\"conductor-human-review-demo\""

if ! "${SCRIPT_DIR}/prove-search.sh" >/tmp/conductor-search-proof.json 2>/tmp/conductor-search-proof.err; then
  echo "搜索 proof 未通过，自动回退到 CLI fallback"
  "${SCRIPT_DIR}/search-output.sh" --threshold "${SEARCH_THRESHOLD}" >/tmp/conductor-search-fallback.json
fi

echo "验证通过:"
echo "  单条 workflow 结果: /tmp/conductor-run-one.json"
echo "  Search proof 成功 : /tmp/conductor-search-proof.json"
echo "  Search fallback   : /tmp/conductor-search-fallback.json"
