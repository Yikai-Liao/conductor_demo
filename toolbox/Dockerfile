ARG DOCKER_IMAGE_PREFIX=docker.io
ARG NOMAD_VERSION=1.11.3
ARG CONSUL_VERSION=1.22.6
ARG VAULT_VERSION=1.21.4

FROM ${DOCKER_IMAGE_PREFIX}/hashicorp/nomad:${NOMAD_VERSION} AS nomad
FROM ${DOCKER_IMAGE_PREFIX}/hashicorp/consul:${CONSUL_VERSION} AS consul
FROM ${DOCKER_IMAGE_PREFIX}/hashicorp/vault:${VAULT_VERSION} AS vault

FROM ${DOCKER_IMAGE_PREFIX}/library/alpine:3.23.3

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache bash bind-tools ca-certificates coreutils curl jq

COPY --from=nomad /bin/nomad /usr/local/bin/nomad
COPY --from=consul /bin/consul /usr/local/bin/consul
COPY --from=vault /bin/vault /usr/local/bin/vault

WORKDIR /workspace
