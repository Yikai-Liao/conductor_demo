#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq
require_command nomad

export NOMAD_ADDR

render_job() {
  local src="$1"
  local dst="$2"

  sed \
    -e "s#@@CONDUCTOR_IMAGE@@#${CONDUCTOR_IMAGE}#g" \
    -e "s#@@CONDUCTOR_UI_IMAGE@@#${CONDUCTOR_UI_IMAGE}#g" \
    -e "s#@@DOCKER_NETWORK@@#${DOCKER_NETWORK}#g" \
    -e "s#@@FUNC1_IMAGE@@#${FUNC1_IMAGE}#g" \
    -e "s#@@FUNC2_IMAGE@@#${FUNC2_IMAGE}#g" \
    -e "s#@@POSTGRES_DB@@#${POSTGRES_DB}#g" \
    -e "s#@@REVIEW_SERVICE_IMAGE@@#${REVIEW_SERVICE_IMAGE}#g" \
    "${src}" > "${dst}"
}

submit_job() {
  local name="$1"
  local src="${ROOT_DIR}/jobs/${name}.nomad.hcl"
  local dst="${ROOT_DIR}/generated/${name}.nomad.hcl"

  render_job "${src}" "${dst}"
  nomad job validate "${dst}" >/dev/null
  nomad job run -detach "${dst}" >/dev/null
  echo "Nomad job 已提交: ${name}"
}

restart_job() {
  local name="$1"
  local output

  if output="$(nomad job restart -yes -on-error=fail "${name}" 2>&1)"; then
    echo "Nomad job 已重启: ${name}"
    return 0
  fi

  if [[ "${output}" == *'is "running"'* ]]; then
    echo "Nomad job 跳过重启（deployment 进行中）: ${name}"
    return 0
  fi

  echo "${output}" >&2
  return 1
}

wait_for_http "Nomad API" "${NOMAD_ADDR}/v1/status/leader"

submit_job "conductor"
submit_job "conductor-ui"

wait_for_consul_service "conductor-api" >/dev/null
wait_for_consul_service "conductor-ui" >/dev/null
restart_job "conductor-ui"
wait_for_consul_service "conductor-ui" >/dev/null

submit_job "func1-python"
submit_job "review-service"
submit_job "func2-ts"

wait_for_consul_service "func1-python" >/dev/null
wait_for_consul_service "review-service" >/dev/null
wait_for_consul_service "func2-ts" >/dev/null
restart_job "func1-python"
restart_job "review-service"
restart_job "func2-ts"
wait_for_consul_service "func1-python" >/dev/null
wait_for_consul_service "review-service" >/dev/null
wait_for_consul_service "func2-ts" >/dev/null
