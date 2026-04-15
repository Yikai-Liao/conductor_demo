#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

attempt=1
response=""
matches="0"

while [[ "${attempt}" -le "${SEARCH_PROOF_MAX_ATTEMPTS}" ]]; do
  response="$(curl -fsS --get \
    --data-urlencode "query=workflowType = 'human_review_demo' AND status = 'COMPLETED'" \
    --data-urlencode "freeText=${SEARCH_PROOF_FREETEXT}" \
    --data-urlencode "size=${SEARCH_PAGE_SIZE}" \
    --data-urlencode "start=0" \
    "${CONDUCTOR_SERVER_URL}/workflow/search")"

  matches="$(echo "${response}" | jq -r '(.results // []) | length')"
  if [[ "${matches}" != "0" ]]; then
    break
  fi

  sleep "${SEARCH_PROOF_POLL_SECONDS}"
  attempt=$((attempt + 1))
done

if [[ "${matches}" == "0" ]]; then
  echo "Conductor search API 未命中 freetext=${SEARCH_PROOF_FREETEXT}" >&2
  exit 1
fi

echo "${response}" | jq '{
  keyword: "'"${SEARCH_PROOF_FREETEXT}"'",
  totalHits: (.totalHits // 0),
  matched: ((.results // []) | length)
}'
