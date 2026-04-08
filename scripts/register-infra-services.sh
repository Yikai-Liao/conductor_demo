#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command curl
require_command docker
require_command jq

container_ip() {
  local service="$1"
  local container_id

  container_id="$(docker compose ps -q "${service}")"
  if [[ -z "${container_id}" ]]; then
    echo "找不到 compose service: ${service}" >&2
    exit 1
  fi

  docker inspect -f "{{with index .NetworkSettings.Networks \"${DOCKER_NETWORK}\"}}{{.IPAddress}}{{end}}" "${container_id}"
}

register_service() {
  local name="$1"
  local address="$2"
  local port="$3"
  local check_json="$4"

  curl -fsS \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg name "${name}" \
      --arg id "${name}" \
      --arg address "${address}" \
      --argjson port "${port}" \
      --argjson check "${check_json}" \
      '{ID:$id, Name:$name, Address:$address, Port:$port, Check:$check}')" \
    "${CONSUL_HTTP_ADDR}/v1/agent/service/register" >/dev/null
}

wait_for_http "Host Consul API" "${CONSUL_HTTP_ADDR}/v1/status/leader"

postgres_ip="$(container_ip "postgres")"
otel_ip="$(container_ip "otel-collector")"

register_service "postgres" "${postgres_ip}" 5432 '{"TCP":"'"${postgres_ip}"':5432","Interval":"10s","Timeout":"2s"}'
register_service "otel-collector-otlp-http" "${otel_ip}" 4318 '{"TCP":"'"${otel_ip}"':4318","Interval":"10s","Timeout":"2s"}'
register_service "otel-collector-metrics" "${otel_ip}" 8889 '{"HTTP":"http://'"${otel_ip}"':8889/metrics","Interval":"10s","Timeout":"2s"}'

echo "infra services 已注册到 Consul"
