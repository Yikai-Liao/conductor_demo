#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env

"${SCRIPT_DIR}/up.sh"
"${SCRIPT_DIR}/seed.sh"

echo "启动完成:"
echo "  Gateway      : ${GATEWAY_URL}"
echo "  Conductor API: ${CONDUCTOR_SERVER_URL}"
echo "  Conductor UI : ${CONDUCTOR_UI_URL}"
echo "  Review API   : ${REVIEW_SERVICE_URL}"
echo "  Nomad UI     : ${NOMAD_ADDR}"
echo "  Consul UI    : ${CONSUL_HTTP_ADDR}"
echo "  Vault UI/API : ${VAULT_ADDR}"
echo "  Grafana      : ${GRAFANA_URL}"
