#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

export NOMAD_ADDR

wait_for_consul_service "conductor-api" >/dev/null
wait_for_consul_service "conductor-ui" >/dev/null
wait_for_consul_service "func1-python" >/dev/null
wait_for_consul_service "func2-ts" >/dev/null
wait_for_consul_service "review-service" >/dev/null

wait_for_http "Nomad API" "${NOMAD_ADDR}/v1/status/leader"
curl -fsS "${NOMAD_ADDR}/v1/job/conductor" >/dev/null
curl -fsS "${NOMAD_ADDR}/v1/job/conductor-ui" >/dev/null
curl -fsS "${NOMAD_ADDR}/v1/job/func1-python" >/dev/null
curl -fsS "${NOMAD_ADDR}/v1/job/func2-ts" >/dev/null
curl -fsS "${NOMAD_ADDR}/v1/job/review-service" >/dev/null

wait_for_contains \
  "func1 task metrics" \
  "${VM_INTERNAL_URL}/api/v1/query?query=sum%20by%20(service)(conductor_demo_task_runs_total)" \
  "func1-python"
wait_for_contains \
  "func2 task metrics" \
  "${VM_INTERNAL_URL}/api/v1/query?query=sum%20by%20(service)(conductor_demo_task_runs_total)" \
  "func2-ts"
wait_for_contains \
  "review metrics" \
  "${VM_INTERNAL_URL}/api/v1/query?query=sum%20by%20(service,decision)(conductor_demo_review_decisions_total)" \
  "review-service"

wait_for_contains \
  "func1 logs" \
  "${VL_INTERNAL_URL}/select/logsql/query?query=service:func1-python%20|%20limit%205" \
  "func1-python"
wait_for_contains \
  "review logs" \
  "${VL_INTERNAL_URL}/select/logsql/query?query=service:review-service%20|%20limit%205" \
  "review-service"
wait_for_contains \
  "trace id logs" \
  "${VL_INTERNAL_URL}/select/logsql/query?query=trace_id:*%20|%20limit%205" \
  "trace_id"

echo "internal verification passed"
