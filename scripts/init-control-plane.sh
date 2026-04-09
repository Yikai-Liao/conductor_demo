#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command consul
require_command curl
require_command jq
require_command nomad

export CONSUL_HTTP_ADDR
export NOMAD_ADDR
export VAULT_ADDR
export VAULT_TOKEN

wait_for_http "Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"
wait_for_http "Vault API" "${VAULT_ADDR}/v1/sys/health"
wait_for_http "Nomad API" "${NOMAD_ADDR}/v1/status/leader"

consul kv put "config/conductor-demo/func1/worker_concurrency" "8" >/dev/null
consul kv put "config/conductor-demo/func1/idle_sleep_seconds" "0.5" >/dev/null
consul kv put "config/conductor-demo/func2/worker_concurrency" "8" >/dev/null
consul kv put "config/conductor-demo/func2/idle_sleep_ms" "500" >/dev/null
consul kv put "config/conductor-demo/review/approval_threshold" "${REVIEW_APPROVAL_THRESHOLD}" >/dev/null
consul kv put "config/conductor-demo/review/max_delay_ms" "${REVIEW_MAX_DELAY_MS}" >/dev/null
consul kv put "config/conductor-demo/review/reject_increment_min" "${REVIEW_REJECT_INCREMENT_MIN}" >/dev/null
consul kv put "config/conductor-demo/review/reject_increment_max" "${REVIEW_REJECT_INCREMENT_MAX}" >/dev/null

vault_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local args=(
    -fsS
    -X "${method}"
    -H "X-Vault-Token: ${VAULT_TOKEN}"
    -H "Content-Type: application/json"
  )

  if [[ -n "${payload}" ]]; then
    args+=(-d "${payload}")
  fi

  curl "${args[@]}" "${VAULT_ADDR}${path}" >/dev/null
}

vault_read() {
  local path="$1"

  curl -fsS \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}${path}"
}

mounts_json="$(vault_read "/v1/sys/mounts")"
if ! echo "${mounts_json}" | jq -e 'has("secret/")' >/dev/null; then
  vault_api \
    "POST" \
    "/v1/sys/mounts/secret" \
    '{"type":"kv","options":{"version":"2"}}'
fi

auth_methods_json="$(vault_read "/v1/sys/auth")"
if ! echo "${auth_methods_json}" | jq -e 'has("jwt-nomad/")' >/dev/null; then
  vault_api "POST" "/v1/sys/auth/jwt-nomad" '{"type":"jwt"}'
fi

vault_api \
  "POST" \
  "/v1/auth/jwt-nomad/config" \
  '{"jwks_url":"http://host.docker.internal:4646/.well-known/jwks.json","jwt_supported_algs":["RS256"],"default_role":"nomad-workloads"}'

auth_methods_json="$(vault_read "/v1/sys/auth")"
jwt_accessor="$(echo "${auth_methods_json}" | jq -r '."jwt-nomad/".accessor')"

vault_policy="$(cat <<EOF
path "secret/data/{{identity.entity.aliases.${jwt_accessor}.metadata.nomad_namespace}}/{{identity.entity.aliases.${jwt_accessor}.metadata.nomad_job_id}}/*" {
  capabilities = ["read"]
}

path "secret/data/{{identity.entity.aliases.${jwt_accessor}.metadata.nomad_namespace}}/{{identity.entity.aliases.${jwt_accessor}.metadata.nomad_job_id}}" {
  capabilities = ["read"]
}

path "secret/metadata/{{identity.entity.aliases.${jwt_accessor}.metadata.nomad_namespace}}/*" {
  capabilities = ["list"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
)"

vault_api \
  "PUT" \
  "/v1/sys/policies/acl/nomad-workloads" \
  "$(jq -nc --arg policy "${vault_policy}" '{policy:$policy}')"

vault_api \
  "POST" \
  "/v1/auth/jwt-nomad/role/nomad-workloads" \
  '{"role_type":"jwt","bound_audiences":["vault.io"],"user_claim":"/nomad_job_id","user_claim_json_pointer":true,"claim_mappings":{"nomad_namespace":"nomad_namespace","nomad_job_id":"nomad_job_id","nomad_task":"nomad_task"},"token_type":"service","token_policies":["nomad-workloads"],"token_period":"30m","token_explicit_max_ttl":0}'

vault_api \
  "POST" \
  "/v1/secret/data/default/conductor/config" \
  "$(jq -nc \
    --arg username "${POSTGRES_USER}" \
    --arg password "${POSTGRES_PASSWORD}" \
    '{data:{username:$username,password:$password}}')"

vault_api \
  "POST" \
  "/v1/secret/data/default/review-service/config" \
  "$(jq -nc \
    --arg api_token "${REVIEW_API_TOKEN}" \
    '{data:{api_token:$api_token}}')"

echo "control-plane 初始化完成"
