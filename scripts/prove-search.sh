#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

response="$(curl -fsS --get \
  --data-urlencode "query=workflowType = 'human_review_demo' AND status = 'COMPLETED'" \
  --data-urlencode "freeText=${SEARCH_PROOF_FREETEXT}" \
  --data-urlencode "size=${SEARCH_PAGE_SIZE}" \
  --data-urlencode "start=0" \
  "${CONDUCTOR_SERVER_URL}/workflow/search")" || {
    echo "Conductor search API freetext proof 失败，建议改用 scripts/search-output.sh 做 fallback" >&2
    exit 1
  }

matches="$(echo "${response}" | jq -r '(.results // []) | length')"
if [[ "${matches}" == "0" ]]; then
  echo "Conductor search API 未命中 freetext=${SEARCH_PROOF_FREETEXT}，建议改用 scripts/search-output.sh 做 fallback" >&2
  exit 1
fi

echo "${response}" | jq '{
  totalHits: (.totalHits // 0),
  matched: ((.results // []) | length)
}'
