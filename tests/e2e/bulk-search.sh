#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"${ROOT_DIR}/scripts/run-bulk.sh" --count 100 --concurrency 16 >/tmp/conductor-bulk-run.json
"${ROOT_DIR}/scripts/search-output.sh" --threshold 10.1
