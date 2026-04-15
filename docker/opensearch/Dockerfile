ARG DOCKER_IMAGE_PREFIX=docker.io
ARG OPENSEARCH_VERSION=2.19.1

FROM ${DOCKER_IMAGE_PREFIX}/opensearchproject/opensearch:${OPENSEARCH_VERSION}

USER root

RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu

USER opensearch
