#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

upsert_taskdef() {
  local file="$1"
  local name
  local method
  local status
  local payload
  local request_body

  name="$(jq -r '.name' "${file}")"
  payload="$(jq -c . "${file}")"
  status="$(curl -s -o /dev/null -w '%{http_code}' "${CONDUCTOR_SERVER_URL}/metadata/taskdefs/${name}")"

  if [[ "${status}" == "200" ]]; then
    method="PUT"
    request_body="${payload}"
  else
    method="POST"
    request_body="[${payload}]"
  fi

  curl -fsS \
    -X "${method}" \
    -H "Content-Type: application/json" \
    -d "${request_body}" \
    "${CONDUCTOR_SERVER_URL}/metadata/taskdefs" >/dev/null

  echo "taskdef 已注册: ${name} (${method})"
}

upsert_workflow() {
  local file="$1"
  local name
  local version
  local method
  local status
  local payload
  local request_body

  name="$(jq -r '.name' "${file}")"
  version="$(jq -r '.version // 1' "${file}")"
  payload="$(jq -c . "${file}")"
  status="$(curl -s -o /dev/null -w '%{http_code}' "${CONDUCTOR_SERVER_URL}/metadata/workflow/${name}?version=${version}")"

  if [[ "${status}" == "200" ]]; then
    method="PUT"
    request_body="[${payload}]"
  else
    method="POST"
    request_body="${payload}"
  fi

  curl -fsS \
    -X "${method}" \
    -H "Content-Type: application/json" \
    -d "${request_body}" \
    "${CONDUCTOR_SERVER_URL}/metadata/workflow" >/dev/null

  echo "workflow 已注册: ${name}:${version} (${method})"
}

upsert_taskdef "${ROOT_DIR}/taskdefs/func1-python.json"
upsert_taskdef "${ROOT_DIR}/taskdefs/func2-ts.json"
upsert_workflow "${ROOT_DIR}/workflows/human-review-demo.json"
