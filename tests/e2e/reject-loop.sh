#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

load_env
require_command curl
require_command jq

workflow_id="$("${ROOT_DIR}/scripts/run-one.sh" --x 1 | jq -r '.workflowId')"
first_pending="$(wait_for_pending_review "${workflow_id}")"
first_task_id="$(echo "${first_pending}" | jq -r '.items[0].taskId')"

review_curl -fsS \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"comment":"第一次人工打回"}' \
  "${REVIEW_SERVICE_URL}/reviews/${first_task_id}/reject" >/dev/null

second_pending="$(wait_for_pending_review "${workflow_id}")"
second_task_id="$(echo "${second_pending}" | jq -r '.items[0].taskId')"

if [[ "${first_task_id}" == "${second_task_id}" ]]; then
  echo "reject 后没有生成新的 review task" >&2
  exit 1
fi

while true; do
  status="$(workflow_status "${workflow_id}")"
  if [[ "${status}" == "COMPLETED" ]]; then
    break
  fi
  review_curl -fsS -X POST "${REVIEW_SERVICE_URL}/reviews/auto-review?workflowId=${workflow_id}&limit=1&concurrency=1" >/dev/null
  sleep 1
done

workflow_json "${workflow_id}" | jq '{workflowId, status, output}'
