#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

x=""
auto_review=0
wait_for_completion=0
review_mode="manual"
approval_threshold="${REVIEW_APPROVAL_THRESHOLD}"
correlation_id=""

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

if [[ -z "${x}" ]]; then
  x="$(pick_default_initial_x)"
fi

if [[ -z "${correlation_id}" ]]; then
  correlation_id="$(build_default_correlation_id "run-one" "${x}" "$(date +%s)-$$")"
fi

workflow_id="$(start_workflow "${x}" "${correlation_id}" "${auto_review}" "${review_mode}" "single" "${approval_threshold}")"

if [[ "${auto_review}" == "1" ]]; then
  if [[ "${wait_for_completion}" == "1" ]]; then
    while true; do
      status="$(workflow_status "${workflow_id}")"

      case "${status}" in
        COMPLETED|FAILED|TERMINATED|TIMED_OUT)
          break
          ;;
        *)
          ;;
      esac

      pending="$(review_curl -fsS "${REVIEW_SERVICE_URL}/reviews/pending?workflowId=${workflow_id}&limit=20")"
      pending_count="$(echo "${pending}" | jq -r '.count')"

      if [[ "${pending_count}" != "0" ]]; then
        review_curl -fsS \
          -X POST \
          "${REVIEW_SERVICE_URL}/reviews/auto-review?workflowId=${workflow_id}&limit=${pending_count}&concurrency=1" >/dev/null
      else
        sleep 1
      fi
    done
  else
    wait_for_pending_review "${workflow_id}" >/dev/null
    review_curl -fsS -X POST "${REVIEW_SERVICE_URL}/reviews/auto-review?workflowId=${workflow_id}&limit=1&concurrency=1" >/dev/null
  fi
fi

if [[ "${wait_for_completion}" == "1" ]]; then
  workflow="$(wait_for_workflow_terminal "${workflow_id}")"
  echo "${workflow}" | jq '{
    workflowId,
    status,
    output
  }'
else
  cn_case_title="$(demo_case_title "${x}")"
  cn_keywords="$(demo_case_keywords "${x}")"
  jq -nc \
    --arg cn_case_title "${cn_case_title}" \
    --arg cn_keywords "${cn_keywords}" \
    --arg correlation_id "${correlation_id}" \
    --arg review_mode "${review_mode}" \
    --arg workflowId "${workflow_id}" \
    --argjson x "${x}" \
    '{
      workflowId: $workflowId,
      x: $x,
      cn_case_title: $cn_case_title,
      cn_keywords: $cn_keywords,
      correlation_id: $correlation_id,
      review_mode: $review_mode
    }'
fi
