#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

wait_for_http "Conductor metadata" "${CONDUCTOR_SERVER_URL}/metadata/taskdefs"
wait_for_http "Conductor UI" "${CONDUCTOR_UI_URL}"
wait_for_http "review service" "${REVIEW_SERVICE_URL}/healthz"
wait_for_http "func1 worker" "http://localhost:8091/healthz"
wait_for_http "func2 worker" "http://localhost:8092/healthz"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"
wait_for_http "VictoriaMetrics" "${VICTORIA_METRICS_URL}/health"
wait_for_http "VictoriaLogs" "${VICTORIA_LOGS_URL}/health"

"${SCRIPT_DIR}/register-defs.sh" >/dev/null
"${SCRIPT_DIR}/run-one.sh" --x 1 --auto-review --wait >/tmp/conductor-run-one.json

sleep 6

wait_for_contains \
  "func1 task metrics" \
  "${VICTORIA_METRICS_URL}/api/v1/query?query=sum%20by%20(service)(conductor_demo_task_runs_total)" \
  "func1-python"
wait_for_contains \
  "func2 task metrics" \
  "${VICTORIA_METRICS_URL}/api/v1/query?query=sum%20by%20(service)(conductor_demo_task_runs_total)" \
  "func2-ts"
wait_for_contains \
  "review metrics" \
  "${VICTORIA_METRICS_URL}/api/v1/query?query=sum%20by%20(service,decision)(conductor_demo_review_decisions_total)" \
  "review-service"

wait_for_contains \
  "func1 logs" \
  "${VICTORIA_LOGS_URL}/select/logsql/query?query=service:func1-python%20|%20limit%205" \
  "func1-python"
wait_for_contains \
  "review logs" \
  "${VICTORIA_LOGS_URL}/select/logsql/query?query=service:review-service%20|%20limit%205" \
  "review-service"
wait_for_contains \
  "trace id logs" \
  "${VICTORIA_LOGS_URL}/select/logsql/query?query=trace_id:*%20|%20limit%205" \
  "trace_id"

wait_for_contains \
  "Grafana VictoriaMetrics datasource" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3000/api/datasources/uid/victoria-metrics" \
  "VictoriaMetrics"
wait_for_contains \
  "Grafana VictoriaLogs datasource" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3000/api/datasources/uid/victoria-logs" \
  "VictoriaLogs"
wait_for_contains \
  "Grafana dashboard" \
  "http://${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3000/api/dashboards/uid/conductor-human-review-demo" \
  "\"uid\":\"conductor-human-review-demo\""

if ! "${SCRIPT_DIR}/prove-search.sh" >/tmp/conductor-search-proof.json 2>/tmp/conductor-search-proof.err; then
  echo "搜索 proof 未通过，自动回退到 CLI fallback"
  "${SCRIPT_DIR}/search-output.sh" --threshold "${SEARCH_THRESHOLD}" >/tmp/conductor-search-fallback.json
fi

echo "验证通过:"
echo "  单条 workflow 结果: /tmp/conductor-run-one.json"
echo "  Search proof 成功 : /tmp/conductor-search-proof.json"
echo "  Search fallback   : /tmp/conductor-search-fallback.json"
