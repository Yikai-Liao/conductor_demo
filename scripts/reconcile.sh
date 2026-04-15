#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command consul
require_command curl
require_command docker
require_command jq
require_command nomad

export CONSUL_HTTP_ADDR
export NOMAD_ADDR
export VAULT_ADDR

"${SCRIPT_DIR}/start-host-proxies.sh"

"${SCRIPT_DIR}/init-vault.sh"
load_env

wait_for_http "Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"
wait_for_http "Nomad API" "${NOMAD_ADDR}/v1/status/leader"
wait_for_http "Gateway" "${GATEWAY_URL}/healthz"

if ! docker image inspect "${CONDUCTOR_UI_IMAGE}" "${FUNC1_IMAGE}" "${FUNC2_IMAGE}" "${REVIEW_SERVICE_IMAGE}" >/dev/null 2>&1; then
  "${SCRIPT_DIR}/build-images.sh"
fi

"${SCRIPT_DIR}/register-infra-services.sh"
"${SCRIPT_DIR}/bootstrap-opensearch.sh"

vault_read_status() {
  local path="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}${path}"
}

nomad_job_exists() {
  local name="$1"
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' "${NOMAD_ADDR}/v1/job/${name}")"
  [[ "${status}" == "200" ]]
}

conductor_taskdef_exists() {
  local name="$1"
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' "${CONDUCTOR_SERVER_URL}/metadata/taskdefs/${name}")"
  [[ "${status}" == "200" ]]
}

conductor_workflow_exists() {
  local name="$1"
  local version="$2"
  local status

  status="$(curl -s -o /dev/null -w '%{http_code}' "${CONDUCTOR_SERVER_URL}/metadata/workflow/${name}?version=${version}")"
  [[ "${status}" == "200" ]]
}

need_control_plane_init=0
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  need_control_plane_init=1
fi
if [[ "${need_control_plane_init}" == "0" && "$(vault_read_status "/v1/secret/data/default/conductor/config")" != "200" ]]; then
  need_control_plane_init=1
fi
if [[ "${need_control_plane_init}" == "0" && "$(vault_read_status "/v1/secret/data/default/review-service/config")" != "200" ]]; then
  need_control_plane_init=1
fi
if [[ "${need_control_plane_init}" == "0" ]]; then
  auth_status="$(curl -sS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth" | jq -r 'has("jwt-nomad/")')"
  if [[ "${auth_status}" != "true" ]]; then
    need_control_plane_init=1
  fi
fi

if [[ "${need_control_plane_init}" == "1" ]]; then
  "${SCRIPT_DIR}/init-control-plane.sh"
fi

need_nomad_submit=0
for job in conductor conductor-ui func1-python review-service func2-ts; do
  if ! nomad_job_exists "${job}"; then
    need_nomad_submit=1
    break
  fi
done

if [[ "${need_nomad_submit}" == "1" ]]; then
  "${SCRIPT_DIR}/nomad-submit.sh"
fi

wait_for_consul_service "conductor-api" >/dev/null
wait_for_consul_service "conductor-ui" >/dev/null
wait_for_consul_service "func1-python" >/dev/null
wait_for_consul_service "review-service" >/dev/null
wait_for_consul_service "func2-ts" >/dev/null

wait_for_http "Conductor metadata" "${CONDUCTOR_SERVER_URL}/metadata/taskdefs"
wait_for_http "Conductor UI" "${CONDUCTOR_UI_URL}"
wait_for_http "review service" "${REVIEW_SERVICE_URL}/healthz"

if ! conductor_taskdef_exists "func1_python" \
  || ! conductor_taskdef_exists "func2_ts" \
  || ! conductor_workflow_exists "human_review_demo" "1"; then
  "${SCRIPT_DIR}/register-defs.sh"
fi

echo "运行时状态已对齐"
