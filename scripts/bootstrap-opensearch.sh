#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_env
require_command jq

reset_indices=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      reset_indices=1
      shift
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

toolbox_wait_for_http \
  "OpenSearch cluster health" \
  "${OPENSEARCH_INTERNAL_URL}/_cluster/health?wait_for_status=yellow&timeout=30s"

plugins_json="$(toolbox_http_get "${OPENSEARCH_INTERNAL_URL}/_cat/plugins?format=json")"
echo "${plugins_json}" | jq -e 'any(.[]; .component == "analysis-icu")' >/dev/null || {
  echo "OpenSearch 缺少 analysis-icu 插件" >&2
  exit 1
}

os_exists() {
  local path="$1"
  if toolbox_exec curl -fsSI "${OPENSEARCH_INTERNAL_URL}${path}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

os_put_file() {
  local path="$1"
  local file="$2"
  toolbox_exec curl -fsS \
    -X PUT \
    -H "Content-Type: application/json" \
    --data-binary "@/workspace/${file}" \
    "${OPENSEARCH_INTERNAL_URL}${path}" >/dev/null
}

os_delete() {
  local path="$1"
  toolbox_exec curl -fsS -X DELETE "${OPENSEARCH_INTERNAL_URL}${path}" >/dev/null
}

verify_cn_mapping() {
  local index_name="$1"
  local mapping_json
  local settings_json

  mapping_json="$(toolbox_http_get "${OPENSEARCH_INTERNAL_URL}/${index_name}/_mapping")"
  settings_json="$(toolbox_http_get "${OPENSEARCH_INTERNAL_URL}/${index_name}/_settings")"

  echo "${mapping_json}" | jq -e --arg index_name "${index_name}" '
    .[$index_name].mappings.properties.input.analyzer == "icu_analyzer"
    and .[$index_name].mappings.properties.input.fields.recall.analyzer == "conductor_cjk_recall"
    and .[$index_name].mappings.properties.input.fields.exact.normalizer == "conductor_lowercase"
    and .[$index_name].mappings.properties.output.analyzer == "icu_analyzer"
    and .[$index_name].mappings.properties.output.fields.recall.analyzer == "conductor_cjk_recall"
    and .[$index_name].mappings.properties.output.fields.exact.normalizer == "conductor_lowercase"
  ' >/dev/null || return 1

  echo "${settings_json}" | jq -e --arg index_name "${index_name}" '
    .[$index_name].settings.index.analysis.analyzer.conductor_cjk_recall.type == "custom"
    and .[$index_name].settings.index.analysis.filter.conductor_cjk_bigram.type == "cjk_bigram"
    and .[$index_name].settings.index.analysis.normalizer.conductor_lowercase.type == "custom"
  ' >/dev/null
}

if [[ "${reset_indices}" == "1" ]]; then
  toolbox_exec curl -fsS -X DELETE "${OPENSEARCH_INTERNAL_URL}/conductor_workflow,conductor_task,conductor_task_log_*,conductor_message_*,conductor_event_*?expand_wildcards=all" >/dev/null || true
fi

os_put_file "/_index_template/template_task_log" "config/opensearch/template_task_log.json"
os_put_file "/_index_template/template_message" "config/opensearch/template_message.json"
os_put_file "/_index_template/template_event" "config/opensearch/template_event.json"

if ! os_exists "/conductor_workflow"; then
  os_put_file "/conductor_workflow" "config/opensearch/workflow-index.json"
fi

if ! os_exists "/conductor_task"; then
  os_put_file "/conductor_task" "config/opensearch/task-index.json"
fi

verify_cn_mapping "conductor_workflow" || {
  echo "conductor_workflow mapping 不符合中文检索要求，请执行 ./scripts/bootstrap-opensearch.sh --reset" >&2
  exit 1
}

verify_cn_mapping "conductor_task" || {
  echo "conductor_task mapping 不符合中文检索要求，请执行 ./scripts/bootstrap-opensearch.sh --reset" >&2
  exit 1
}

echo "OpenSearch bootstrap 完成"
