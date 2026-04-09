#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command jq

mkdir -p "${VAULT_STATE_DIR}"
chmod 700 "${VAULT_STATE_DIR}"

wait_for_vault_api() {
  local max_attempts="${1:-90}"
  local attempt=1

  while true; do
    if curl -sS "${VAULT_ADDR}/v1/sys/seal-status" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      echo "等待 Vault API 超时: ${VAULT_ADDR}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

vault_read_json() {
  curl -fsS "${VAULT_ADDR}/v1/sys/seal-status"
}

wait_for_vault_api

seal_status_json="$(vault_read_json)"
initialized="$(echo "${seal_status_json}" | jq -r '.initialized')"

if [[ "${initialized}" != "true" ]]; then
  init_json="$(curl -fsS \
    -X PUT \
    -H "Content-Type: application/json" \
    -d '{"secret_shares":1,"secret_threshold":1}' \
    "${VAULT_ADDR}/v1/sys/init")"

  root_token="$(echo "${init_json}" | jq -r '.root_token')"
  unseal_key="$(echo "${init_json}" | jq -r '.keys_base64[0]')"

  printf '%s\n' "${root_token}" > "${VAULT_ROOT_TOKEN_FILE}"
  printf '%s\n' "${unseal_key}" > "${VAULT_UNSEAL_KEY_FILE}"
  chmod 600 "${VAULT_ROOT_TOKEN_FILE}" "${VAULT_UNSEAL_KEY_FILE}"

  seal_status_json="$(vault_read_json)"
fi

if [[ ! -f "${VAULT_UNSEAL_KEY_FILE}" ]]; then
  echo "缺少 Vault unseal key 文件: ${VAULT_UNSEAL_KEY_FILE}" >&2
  exit 1
fi

sealed="$(echo "${seal_status_json}" | jq -r '.sealed')"
if [[ "${sealed}" == "true" ]]; then
  unseal_key="$(tr -d '[:space:]' < "${VAULT_UNSEAL_KEY_FILE}")"
  curl -fsS \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg key "${unseal_key}" '{key:$key}')" \
    "${VAULT_ADDR}/v1/sys/unseal" >/dev/null
fi

if [[ -f "${VAULT_ROOT_TOKEN_FILE}" ]]; then
  export VAULT_TOKEN="$(tr -d '[:space:]' < "${VAULT_ROOT_TOKEN_FILE}")"
fi

echo "Vault 已就绪: ${VAULT_ADDR}"
