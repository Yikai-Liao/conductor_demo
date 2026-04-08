#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

count="${RUN_BULK_COUNT}"
concurrency="${RUN_BULK_CONCURRENCY}"
auto_review=1
approval_threshold="${REVIEW_APPROVAL_THRESHOLD}"
run_id="bulk-$(date +%s)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      count="$2"
      shift 2
      ;;
    --concurrency)
      concurrency="$2"
      shift 2
      ;;
    --no-auto-review)
      auto_review=0
      shift
      ;;
    --approval-threshold)
      approval_threshold="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

tmp_ids="$(mktemp)"
active=0

submit_one() {
  local index="$1"
  local x_value=$(( ((index - 1) % 2) + 1 ))
  local correlation_id

  correlation_id="$(build_default_correlation_id "${run_id}" "${x_value}" "${index}")"
  start_workflow \
    "${x_value}" \
    "${correlation_id}" \
    "${auto_review}" \
    "auto" \
    "${run_id}" \
    "${approval_threshold}" >> "${tmp_ids}"
}

for index in $(seq 1 "${count}"); do
  submit_one "${index}" &
  active=$((active + 1))
  if (( active >= concurrency )); then
    wait -n
    active=$((active - 1))
  fi
done

wait

submitted="$(wc -l < "${tmp_ids}" | tr -d ' ')"

if [[ "${auto_review}" == "1" ]]; then
  while true; do
    terminal_counts="$(count_terminal_workflows "${tmp_ids}")"
    terminal="${terminal_counts%/*}"
    total="${terminal_counts#*/}"

    if [[ "${terminal}" == "${total}" ]]; then
      break
    fi

    review_curl -fsS \
      -X POST \
      "${REVIEW_SERVICE_URL}/reviews/auto-review?limit=${count}&concurrency=${AUTO_REVIEW_CONCURRENCY}" >/dev/null || true
    sleep 1
  done
fi

terminal_counts="$(count_terminal_workflows "${tmp_ids}")"
terminal="${terminal_counts%/*}"
total="${terminal_counts#*/}"

jq -nc \
  --arg ids_file "${tmp_ids}" \
  --arg run_id "${run_id}" \
  --argjson submitted "${submitted}" \
  --argjson terminal "${terminal}" \
  --argjson total "${total}" \
  '{
    run_id: $run_id,
    ids_file: $ids_file,
    submitted: $submitted,
    terminal: $terminal,
    total: $total
  }'
