#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env

"${SCRIPT_DIR}/build-images.sh"
"${SCRIPT_DIR}/init-control-plane.sh"
"${SCRIPT_DIR}/nomad-submit.sh"

wait_for_http "Conductor metadata" "${CONDUCTOR_SERVER_URL}/metadata/taskdefs"
wait_for_http "Conductor UI" "${CONDUCTOR_UI_URL}"
wait_for_http "review service" "${REVIEW_SERVICE_URL}/healthz"

"${SCRIPT_DIR}/register-defs.sh"

echo "控制面已初始化"
