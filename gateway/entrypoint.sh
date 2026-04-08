#!/usr/bin/env bash

set -euo pipefail

readonly TEMPLATE_PATH="/etc/nginx/templates/default.conf.template"
readonly OUTPUT_PATH="/etc/nginx/conf.d/default.conf"
readonly CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://consul:8500}"
readonly GATEWAY_PORT="${GATEWAY_PORT:-8080}"
readonly GATEWAY_REFRESH_SECONDS="${GATEWAY_REFRESH_SECONDS:-5}"

consul_curl() {
  curl --noproxy "*" -fsS "$@"
}

resolve_service() {
  local service_name="$1"
  local fallback="$2"
  local response
  local address
  local port

  response="$(consul_curl "${CONSUL_HTTP_ADDR}/v1/health/service/${service_name}?passing=1" 2>/dev/null || true)"
  if [[ -z "${response}" || "${response}" == "[]" ]]; then
    echo "${fallback}"
    return 0
  fi

  address="$(echo "${response}" | jq -r '.[0].Service.Address // empty')"
  if [[ -z "${address}" || "${address}" == "null" ]]; then
    address="$(echo "${response}" | jq -r '.[0].Node.Address // empty')"
  fi
  port="$(echo "${response}" | jq -r '.[0].Service.Port // empty')"

  if [[ -z "${address}" || -z "${port}" || "${port}" == "null" ]]; then
    echo "${fallback}"
    return 0
  fi

  echo "${address}:${port}"
}

render_config() {
  local conductor_api
  local conductor_ui
  local review_service

  conductor_api="$(resolve_service "conductor-api" "127.0.0.1:65535")"
  conductor_ui="$(resolve_service "conductor-ui" "127.0.0.1:65535")"
  review_service="$(resolve_service "review-service" "127.0.0.1:65535")"

  sed \
    -e "s#@@CONDUCTOR_API@@#${conductor_api}#g" \
    -e "s#@@CONDUCTOR_UI@@#${conductor_ui}#g" \
    -e "s#@@REVIEW_SERVICE@@#${review_service}#g" \
    -e "s#@@GATEWAY_PORT@@#${GATEWAY_PORT}#g" \
    "${TEMPLATE_PATH}" > "${OUTPUT_PATH}.tmp"

  if [[ ! -f "${OUTPUT_PATH}" ]] || ! cmp -s "${OUTPUT_PATH}.tmp" "${OUTPUT_PATH}"; then
    mv "${OUTPUT_PATH}.tmp" "${OUTPUT_PATH}"
    if pgrep nginx >/dev/null 2>&1; then
      nginx -s reload >/dev/null 2>&1 || true
    fi
    return 0
  fi

  rm -f "${OUTPUT_PATH}.tmp"
}

render_config

(
  while true; do
    sleep "${GATEWAY_REFRESH_SECONDS}"
    render_config
  done
) &

exec nginx -g "daemon off;"
