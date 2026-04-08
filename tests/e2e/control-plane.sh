#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/common.sh"

load_env
require_command curl
require_command docker
require_command jq
require_command nomad

nomad job status "conductor" >/dev/null
nomad job status "conductor-ui" >/dev/null
nomad job status "func1-python" >/dev/null
nomad job status "func2-ts" >/dev/null
nomad job status "review-service" >/dev/null

curl -fsS "${CONSUL_HTTP_ADDR}/v1/catalog/service/conductor-api" | jq 'length > 0' >/dev/null
curl -fsS "${CONSUL_HTTP_ADDR}/v1/catalog/service/conductor-ui" | jq 'length > 0' >/dev/null
curl -fsS "${CONSUL_HTTP_ADDR}/v1/catalog/service/review-service" | jq 'length > 0' >/dev/null

curl -fsS \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/secret/data/default/review-service/config" | jq -e '.data.data.api_token | length > 0' >/dev/null

compose_forbidden_ports="$(
  docker compose ps --format json | jq -sr '
    map(
      select(
        ((.Publishers // []) | map(select((.PublishedPort // 0) > 0)) | length) > 0
        and
        ((.Service // "") | test("^(gateway|vault|grafana)$") | not)
      )
    )
    | .[]
    | "\(.Names) "
      + (
        (.Publishers // [])
        | map(select((.PublishedPort // 0) > 0) | "\(.URL):\(.PublishedPort)->\(.TargetPort)/\(.Protocol)")
        | join(", ")
      )
  '
)"

nomad_forbidden_ports="$(
  docker ps --filter label=com.hashicorp.nomad.alloc_id --format json | jq -sr '
    map(select((.Ports // "") | contains("->")))
    | .[]
    | "\(.Names) \(.Ports)"
  '
)"

published_ports="$(printf '%s\n%s\n' "${compose_forbidden_ports}" "${nomad_forbidden_ports}" | sed '/^$/d')"
if [[ -n "${published_ports}" ]]; then
  echo "检测到不允许的宿主机端口暴露" >&2
  echo "${published_ports}" >&2
  exit 1
fi

echo "control-plane verification passed"
