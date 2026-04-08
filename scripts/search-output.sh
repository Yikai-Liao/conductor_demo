#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

threshold="${SEARCH_THRESHOLD}"
size="${SEARCH_PAGE_SIZE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)
      threshold="$2"
      shift 2
      ;;
    --size)
      size="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

response="$(curl -fsS --get \
  --data-urlencode "query=workflowType = 'human_review_demo' AND status = 'COMPLETED'" \
  --data-urlencode "size=${size}" \
  --data-urlencode "start=0" \
  "${CONDUCTOR_SERVER_URL}/workflow/search")"

echo "${response}" | jq --argjson threshold "${threshold}" '
  [
    (.results // [])[]
    | . as $workflow
    | (
        if ($workflow.output | type) == "string" then
          ($workflow.output | try fromjson catch {})
        else
          ($workflow.output // {})
        end
      ) as $output
    | ($output.y // 0 | tonumber? // 0) as $y
    | select($y > $threshold)
    | {
        workflowId: ($workflow.workflowId // $workflow.workflowId),
        status: $workflow.status,
        correlation_id: ($workflow.correlationId // $output.correlation_id // ""),
        initial_x: ($output.initial_x // null),
        initial_x_tag: ($output.initial_x_tag // ""),
        y: $y,
        y_tag: ($output.y_tag // ""),
        comment: ($output.comment // ""),
        trace_id: ($output.trace_id // ""),
        attempts: ($output.attempts // 0)
      }
  ]'
