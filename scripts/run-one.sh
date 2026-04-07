#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

x=1
auto_review=0
wait_for_completion=0
review_mode="manual"
approval_threshold="${REVIEW_APPROVAL_THRESHOLD}"
correlation_id="run-one-$(date +%s)-$$"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --x)
      x="$2"
      shift 2
      ;;
    --auto-review)
      auto_review=1
      review_mode="auto"
      shift
      ;;
    --wait)
      wait_for_completion=1
      shift
      ;;
    --approval-threshold)
      approval_threshold="$2"
      shift 2
      ;;
    --correlation-id)
      correlation_id="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

workflow_id="$(start_workflow "${x}" "${correlation_id}" "${auto_review}" "${review_mode}" "single" "${approval_threshold}")"

if [[ "${auto_review}" == "1" ]]; then
  wait_for_pending_review "${workflow_id}" >/dev/null
  curl -fsS -X POST "${REVIEW_SERVICE_URL}/reviews/auto-review?workflowId=${workflow_id}&limit=1&concurrency=1" >/dev/null
fi

if [[ "${wait_for_completion}" == "1" ]]; then
  workflow="$(wait_for_workflow_terminal "${workflow_id}")"
  echo "${workflow}" | jq '{
    workflowId,
    status,
    output
  }'
else
  jq -nc \
    --arg correlation_id "${correlation_id}" \
    --arg review_mode "${review_mode}" \
    --arg workflowId "${workflow_id}" \
    --argjson x "${x}" \
    '{
      workflowId: $workflowId,
      x: $x,
      correlation_id: $correlation_id,
      review_mode: $review_mode
    }'
fi
