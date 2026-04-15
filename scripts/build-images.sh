#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command docker
require_command curl

build_args=(
  --build-arg "DOCKER_IMAGE_PREFIX=${DOCKER_IMAGE_PREFIX}"
)

cd "${ROOT_DIR}"

conductor_source_dir="${ROOT_DIR}/generated/conductor-source"
conductor_source_archive="${conductor_source_dir}/conductor-source.tar.gz"
conductor_source_version_file="${conductor_source_dir}/conductor-source.version"

mkdir -p "${conductor_source_dir}"

if [[ ! -f "${conductor_source_archive}" ]] \
  || [[ ! -f "${conductor_source_version_file}" ]] \
  || [[ "$(cat "${conductor_source_version_file}")" != "${CONDUCTOR_VERSION}" ]]; then
  tmp_archive="${conductor_source_archive}.tmp"
  curl -fsSL "https://github.com/conductor-oss/conductor/archive/refs/tags/v${CONDUCTOR_VERSION}.tar.gz" -o "${tmp_archive}"
  mv "${tmp_archive}" "${conductor_source_archive}"
  printf '%s' "${CONDUCTOR_VERSION}" > "${conductor_source_version_file}"
fi

docker build --network host "${build_args[@]}" --build-arg "CONDUCTOR_VERSION=${CONDUCTOR_VERSION}" -f "docker/conductor-server/Dockerfile" -t "${CONDUCTOR_IMAGE}" .
docker build --network host "${build_args[@]}" --build-arg "CONDUCTOR_VERSION=${CONDUCTOR_VERSION}" -f "docker/conductor-ui/Dockerfile" -t "${CONDUCTOR_UI_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/func1-python/Dockerfile" -t "${FUNC1_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/func2-ts/Dockerfile" -t "${FUNC2_IMAGE}" .
docker build --network host "${build_args[@]}" -f "docker/review-service/Dockerfile" -t "${REVIEW_SERVICE_IMAGE}" .

echo "镜像已构建:"
echo "  ${CONDUCTOR_IMAGE}"
echo "  ${CONDUCTOR_UI_IMAGE}"
echo "  ${FUNC1_IMAGE}"
echo "  ${FUNC2_IMAGE}"
echo "  ${REVIEW_SERVICE_IMAGE}"
