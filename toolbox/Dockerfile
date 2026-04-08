ARG NOMAD_VERSION=1.8.4
ARG CONSUL_VERSION=1.19.1
ARG VAULT_VERSION=1.17.6

FROM hashicorp/nomad:${NOMAD_VERSION} AS nomad
FROM hashicorp/consul:${CONSUL_VERSION} AS consul
FROM hashicorp/vault:${VAULT_VERSION} AS vault

FROM alpine:3.20

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ARG NOMAD_VERSION
ARG CONSUL_VERSION
ARG VAULT_VERSION

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV ALL_PROXY=${ALL_PROXY}
ENV NO_PROXY=${NO_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV all_proxy=${ALL_PROXY}
ENV no_proxy=${NO_PROXY}

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache bash bind-tools ca-certificates coreutils curl jq

COPY --from=nomad /bin/nomad /usr/local/bin/nomad
COPY --from=consul /bin/consul /usr/local/bin/consul
COPY --from=vault /bin/vault /usr/local/bin/vault

WORKDIR /workspace
