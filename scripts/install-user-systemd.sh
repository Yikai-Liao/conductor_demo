#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command docker
require_command jq
require_command systemctl

if [[ -d "/usr/lib/systemd" && -x "/usr/lib/systemd/systemd-socket-proxyd" ]]; then
  systemd_socket_proxyd="/usr/lib/systemd/systemd-socket-proxyd"
elif command -v systemd-socket-proxyd >/dev/null 2>&1; then
  systemd_socket_proxyd="$(command -v systemd-socket-proxyd)"
else
  echo "找不到 systemd-socket-proxyd" >&2
  exit 1
fi

docker_host_gateway_addr="$(
  docker network inspect bridge --format '{{json .IPAM.Config}}' \
    | jq -r '.[0].Gateway'
)"

if [[ -z "${docker_host_gateway_addr}" || "${docker_host_gateway_addr}" == "null" ]]; then
  echo "无法解析 Docker host gateway 地址" >&2
  exit 1
fi

unit_dir="${HOME}/.config/systemd/user"
mkdir -p "${unit_dir}"

render_unit() {
  local src="$1"
  local dst="$2"

  sed \
    -e "s#@@ROOT_DIR@@#${ROOT_DIR}#g" \
    -e "s#@@DOCKER_HOST_GATEWAY_ADDR@@#${docker_host_gateway_addr}#g" \
    -e "s#@@SYSTEMD_SOCKET_PROXYD@@#${systemd_socket_proxyd}#g" \
    "${src}" > "${dst}"
}

for unit in "${ROOT_DIR}"/systemd/*; do
  render_unit "${unit}" "${unit_dir}/$(basename "${unit}")"
done

systemctl --user daemon-reload

echo "user systemd 单元已安装到 ${unit_dir}"
echo "Docker host gateway 地址: ${docker_host_gateway_addr}"
echo "可执行:"
echo "  systemctl --user enable --now conductor-demo.target"
echo "  systemctl --user status conductor-demo.target"
