#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command docker

build_args=()

for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
  value="${!key:-}"
  if [[ -n "${value}" ]]; then
    build_args+=(--build-arg "${key}=${value}")
  fi
done

cd "${ROOT_DIR}"

docker build --network host "${build_args[@]}" -f "docker/conductor-ui/Dockerfile" -t "${CONDUCTOR_UI_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/func1-python/Dockerfile" -t "${FUNC1_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/func2-ts/Dockerfile" -t "${FUNC2_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/review-service/Dockerfile" -t "${REVIEW_SERVICE_IMAGE}" .

echo "镜像已构建:"
echo "  ${CONDUCTOR_UI_IMAGE}"
echo "  ${FUNC1_IMAGE}"
echo "  ${FUNC2_IMAGE}"
echo "  ${REVIEW_SERVICE_IMAGE}"
