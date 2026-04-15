ARG DOCKER_IMAGE_PREFIX=docker.io
ARG GRAFANA_VERSION=12.4.2
FROM ${DOCKER_IMAGE_PREFIX}/grafana/grafana:${GRAFANA_VERSION}

ARG VICTORIALOGS_PLUGIN_VERSION=0.26.3

ENV GF_PATHS_PLUGINS=/opt/grafana-plugins

COPY docker/grafana/vendor/victoriametrics-logs-datasource.tar.gz /tmp/victorialogs-plugin.tar.gz

USER root

RUN mkdir -p "${GF_PATHS_PLUGINS}" \
    && tar -xzf /tmp/victorialogs-plugin.tar.gz -C "${GF_PATHS_PLUGINS}" \
    && chown -R grafana:root "${GF_PATHS_PLUGINS}" \
    && rm -f /tmp/victorialogs-plugin.tar.gz

USER grafana
