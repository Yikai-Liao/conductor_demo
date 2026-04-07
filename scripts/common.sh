#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

load_env() {
  if [[ -f "${ROOT_DIR}/.env.example" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${ROOT_DIR}/.env.example"
    set +a
  fi

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${ROOT_DIR}/.env"
    set +a
  fi

  : "${CONDUCTOR_SERVER_URL:=http://localhost:8080/api}"
  : "${CONDUCTOR_UI_URL:=http://localhost:8127}"
  : "${REVIEW_SERVICE_URL:=http://localhost:8090}"
  : "${GRAFANA_URL:=http://localhost:3000}"
  : "${VICTORIA_METRICS_URL:=http://localhost:8428}"
  : "${VICTORIA_LOGS_URL:=http://localhost:9428}"
  : "${REVIEW_APPROVAL_THRESHOLD:=5}"
  : "${RUN_BULK_COUNT:=1000}"
  : "${RUN_BULK_CONCURRENCY:=32}"
  : "${AUTO_REVIEW_CONCURRENCY:=32}"
  : "${SEARCH_THRESHOLD:=10.1}"
  : "${SEARCH_PAGE_SIZE:=1000}"
  : "${SEARCH_PROOF_FREETEXT:=output.y:>10.1}"
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "缺少命令: ${cmd}" >&2
    exit 1
  fi
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local max_attempts="${3:-90}"
  local attempt=1

  until curl -fsS "${url}" >/dev/null 2>&1; do
    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "等待 ${name} 超时: ${url}" >&2
      exit 1
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
}

wait_for_contains() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local max_attempts="${4:-60}"
  local attempt=1
  local response

  while true; do
    response="$(curl -fsS "${url}")"
    if [[ "${response}" == *"${expected}"* ]]; then
      return 0
    fi

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "${name} 未命中预期文本: ${expected}" >&2
      echo "${response}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

workflow_json() {
  local workflow_id="$1"
  curl -fsS "${CONDUCTOR_SERVER_URL}/workflow/${workflow_id}?includeTasks=true"
}

workflow_status() {
  local workflow_id="$1"
  workflow_json "${workflow_id}" | jq -r '.status'
}

wait_for_workflow_terminal() {
  local workflow_id="$1"
  local max_attempts="${2:-180}"
  local attempt=1
  local response
  local status

  while true; do
    response="$(workflow_json "${workflow_id}")"
    status="$(echo "${response}" | jq -r '.status')"

    case "${status}" in
      COMPLETED|FAILED|TERMINATED|TIMED_OUT)
        echo "${response}"
        return 0
        ;;
      *)
        ;;
    esac

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "等待 workflow 终态超时: ${workflow_id}" >&2
      echo "${response}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

wait_for_pending_review() {
  local workflow_id="$1"
  local max_attempts="${2:-120}"
  local attempt=1
  local response
  local count

  while true; do
    response="$(curl -fsS "${REVIEW_SERVICE_URL}/reviews/pending?workflowId=${workflow_id}&limit=20")"
    count="$(echo "${response}" | jq -r '.count')"
    if [[ "${count}" != "0" ]]; then
      echo "${response}"
      return 0
    fi

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "等待 pending review 超时: ${workflow_id}" >&2
      echo "${response}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

start_workflow_payload() {
  local x="$1"
  local correlation_id="$2"
  local auto_review="$3"
  local review_mode="$4"
  local bulk_seed="$5"
  local approval_threshold="$6"

  jq -nc \
    --arg correlation_id "${correlation_id}" \
    --arg review_mode "${review_mode}" \
    --arg bulk_seed "${bulk_seed}" \
    --argjson x "${x}" \
    --argjson auto_review "${auto_review}" \
    --argjson approval_threshold "${approval_threshold}" \
    '{
      x: $x,
      correlation_id: $correlation_id,
      auto_review: $auto_review,
      review_mode: $review_mode,
      bulk_seed: $bulk_seed,
      approval_threshold: $approval_threshold
    }'
}

start_workflow() {
  local x="$1"
  local correlation_id="$2"
  local auto_review="$3"
  local review_mode="$4"
  local bulk_seed="$5"
  local approval_threshold="$6"
  local payload

  payload="$(start_workflow_payload "${x}" "${correlation_id}" "${auto_review}" "${review_mode}" "${bulk_seed}" "${approval_threshold}")"
  curl -fsS \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${CONDUCTOR_SERVER_URL}/workflow/human_review_demo" | tr -d '"'
}

count_terminal_workflows() {
  local file="$1"
  local terminal=0
  local total=0
  local workflow_id
  local status

  while IFS= read -r workflow_id; do
    [[ -z "${workflow_id}" ]] && continue
    total=$((total + 1))
    status="$(workflow_status "${workflow_id}")"
    case "${status}" in
      COMPLETED|FAILED|TERMINATED|TIMED_OUT)
        terminal=$((terminal + 1))
        ;;
      *)
        ;;
    esac
  done < "${file}"

  echo "${terminal}/${total}"
}
