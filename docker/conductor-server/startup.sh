#!/bin/sh

set -eu

echo "Starting Conductor server"

if [ -n "${CONFIG_PROP:-}" ]; then
  config_file="/app/config/${CONFIG_PROP}"
else
  config_file="/app/config/config.properties"
fi

echo "Property file: ${config_file}"
echo "Using java options: ${JAVA_OPTS:-}"

exec java ${JAVA_OPTS:-} -DCONDUCTOR_CONFIG_FILE="${config_file}" -jar conductor-server.jar
