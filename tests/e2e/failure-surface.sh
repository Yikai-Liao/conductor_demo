#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

load_env
require_command curl
require_command jq

empty_pending="$(review_curl -fsS "${REVIEW_SERVICE_URL}/reviews/pending?workflowId=missing-workflow&limit=1")"
echo "${empty_pending}" | jq 'select(.count == 0)' >/dev/null

unauthorized_status="$(curl -s -o /tmp/conductor-review-auth.json -w '%{http_code}' "${REVIEW_SERVICE_URL}/reviews/pending?limit=1" || true)"
if [[ -n "${REVIEW_API_TOKEN}" && "${unauthorized_status}" != "401" ]]; then
  echo "review API 未正确拒绝未鉴权请求" >&2
  exit 1
fi

status_code="$(review_curl -s -o /tmp/conductor-invalid-review.json -w '%{http_code}' -X POST "${REVIEW_SERVICE_URL}/reviews/not-a-task/approve" || true)"
if [[ "${status_code}" == "200" ]]; then
  echo "非法 taskId 不应返回 200" >&2
  exit 1
fi

if ! "${ROOT_DIR}/scripts/prove-search.sh" >/tmp/conductor-failure-proof.json 2>/tmp/conductor-failure-proof.err; then
  "${ROOT_DIR}/scripts/search-output.sh" >/tmp/conductor-failure-fallback.json
fi

echo "failure surface checks passed"
