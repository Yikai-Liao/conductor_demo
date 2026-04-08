#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

load_env() {
  local preserve_keys=(
    CONSUL_HTTP_ADDR
    CONDUCTOR_SERVER_URL
    CONDUCTOR_SWAGGER_URL
    CONDUCTOR_UI_URL
    GATEWAY_URL
    GRAFANA_URL
    NOMAD_ADDR
    REVIEW_SERVICE_URL
    VAULT_ADDR
    VAULT_TOKEN
    VL_INTERNAL_URL
    VM_INTERNAL_URL
  )
  local key

  for key in "${preserve_keys[@]}"; do
    eval "__preserve_${key}=\${${key}-__UNSET__}"
  done

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

  for key in "${preserve_keys[@]}"; do
    eval "preserved_value=\${__preserve_${key}}"
    if [[ "${preserved_value}" != "__UNSET__" ]]; then
      printf -v "${key}" '%s' "${preserved_value}"
      export "${key}"
    fi
  done

  : "${DOCKER_NETWORK:=conductor-demo}"
  : "${GATEWAY_URL:=http://localhost:18080}"
  : "${CONDUCTOR_SERVER_URL:=${GATEWAY_URL}/api}"
  : "${CONDUCTOR_UI_URL:=${GATEWAY_URL}}"
  : "${REVIEW_SERVICE_URL:=${GATEWAY_URL}/review}"
  : "${NOMAD_ADDR:=http://127.0.0.1:4646}"
  : "${CONSUL_HTTP_ADDR:=http://127.0.0.1:8500}"
  : "${VAULT_ADDR:=http://localhost:18200}"
  : "${VAULT_TOKEN:=root}"
  : "${GRAFANA_URL:=http://localhost:13000}"
  : "${VM_INTERNAL_URL:=http://victoria-metrics:8428}"
  : "${VL_INTERNAL_URL:=http://victoria-logs:9428}"
  : "${REVIEW_API_TOKEN:=review-demo-token}"
  : "${REVIEW_APPROVAL_THRESHOLD:=5}"
  : "${REVIEW_MAX_DELAY_MS:=5000}"
  : "${REVIEW_REJECT_INCREMENT_MIN:=0.10}"
  : "${REVIEW_REJECT_INCREMENT_MAX:=1.00}"
  : "${RUN_BULK_COUNT:=1000}"
  : "${RUN_BULK_CONCURRENCY:=32}"
  : "${AUTO_REVIEW_CONCURRENCY:=32}"
  : "${SEARCH_THRESHOLD:=10.1}"
  : "${SEARCH_PAGE_SIZE:=1000}"
  : "${SEARCH_PROOF_FREETEXT:=output.y:>10.1}"
  : "${CONDUCTOR_VERSION:=3.22.2}"
  : "${POSTGRES_DB:=conductor}"
  : "${POSTGRES_USER:=conductor}"
  : "${POSTGRES_PASSWORD:=conductor}"
  : "${CONDUCTOR_UI_IMAGE:=conductor-demo/conductor-ui:dev}"
  : "${FUNC1_IMAGE:=conductor-demo/func1-python:dev}"
  : "${FUNC2_IMAGE:=conductor-demo/func2-ts:dev}"
  : "${REVIEW_SERVICE_IMAGE:=conductor-demo/review-service:dev}"
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "缺少命令: ${cmd}" >&2
    exit 1
  fi
}

ensure_runtime_dirs() {
  mkdir -p \
    "${ROOT_DIR}/generated" \
    "${ROOT_DIR}/runtime/host-consul" \
    "${ROOT_DIR}/runtime/host-nomad" \
    "${ROOT_DIR}/runtime/postgres" \
    "${ROOT_DIR}/runtime/vector" \
    "${ROOT_DIR}/runtime/vault" \
    "${ROOT_DIR}/runtime/victoria-logs" \
    "${ROOT_DIR}/runtime/victoria-metrics" \
    "${ROOT_DIR}/runtime/vmagent"
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

wait_for_consul_service() {
  local service_name="$1"
  local max_attempts="${2:-90}"
  local attempt=1
  local response

  while true; do
    response="$(curl -fsS "${CONSUL_HTTP_ADDR}/v1/health/service/${service_name}?passing=1" 2>/dev/null || true)"
    if [[ -n "${response}" && "${response}" != "[]" ]]; then
      echo "${response}"
      return 0
    fi

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "等待 Consul 服务超时: ${service_name}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

toolbox_exec() {
  docker compose exec -T toolbox "$@"
}

render_config_template() {
  local src="$1"
  local dst="$2"

  sed -e "s#@@ROOT_DIR@@#${ROOT_DIR}#g" "${src}" > "${dst}"
}

review_curl() {
  if [[ -n "${REVIEW_API_TOKEN:-}" ]]; then
    curl -H "Authorization: Bearer ${REVIEW_API_TOKEN}" "$@"
  else
    curl "$@"
  fi
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
    response="$(review_curl -fsS "${REVIEW_SERVICE_URL}/reviews/pending?workflowId=${workflow_id}&limit=20")"
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

format_initial_x_token() {
  local x="$1"
  printf '%s' "${x}" | tr -c '[:alnum:]' '_'
}

initial_x_tag() {
  local x="$1"
  printf 'initial_x_%s' "$(format_initial_x_token "${x}")"
}

build_default_correlation_id() {
  local scope="$1"
  local x="$2"
  local suffix="$3"
  printf '%s-x%s-%s' "${scope}" "$(format_initial_x_token "${x}")" "${suffix}"
}

pick_default_initial_x() {
  local state_dir="${ROOT_DIR}/runtime/cli-state"
  local state_file="${state_dir}/last-initial-x"
  local last_x=""
  local next_x="1"

  ensure_runtime_dirs
  mkdir -p "${state_dir}"

  if [[ -f "${state_file}" ]]; then
    last_x="$(tr -d '[:space:]' < "${state_file}")"
  fi

  if [[ "${last_x}" == "1" ]]; then
    next_x="2"
  fi

  printf '%s\n' "${next_x}" > "${state_file}"
  printf '%s\n' "${next_x}"
}

start_workflow_payload() {
  local x="$1"
  local correlation_id="$2"
  local auto_review="$3"
  local review_mode="$4"
  local bulk_seed="$5"
  local approval_threshold="$6"
  local initial_x_tag_value

  initial_x_tag_value="$(initial_x_tag "${x}")"

  jq -nc \
    --arg correlation_id "${correlation_id}" \
    --arg initial_x_tag "${initial_x_tag_value}" \
    --arg review_mode "${review_mode}" \
    --arg bulk_seed "${bulk_seed}" \
    --argjson x "${x}" \
    --argjson auto_review "${auto_review}" \
    --argjson approval_threshold "${approval_threshold}" \
    '{
      name: "human_review_demo",
      version: 1,
      correlationId: $correlation_id,
      input: {
        x: $x,
        correlation_id: $correlation_id,
        initial_x_tag: $initial_x_tag,
        auto_review: $auto_review,
        review_mode: $review_mode,
        bulk_seed: $bulk_seed,
        approval_threshold: $approval_threshold
      }
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
    "${CONDUCTOR_SERVER_URL}/workflow" | tr -d '"'
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
