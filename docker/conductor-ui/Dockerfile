ARG CONDUCTOR_VERSION=3.22.2

FROM node:20-bookworm-slim AS builder

ARG CONDUCTOR_VERSION
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV ALL_PROXY=${ALL_PROXY}
ENV NO_PROXY=${NO_PROXY}
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV all_proxy=${ALL_PROXY}
ENV no_proxy=${NO_PROXY}

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN curl -fsSL "https://github.com/conductor-oss/conductor/archive/refs/tags/v${CONDUCTOR_VERSION}.tar.gz" \
    | tar -xz --strip-components=1

WORKDIR /src/ui

RUN npm config set registry https://registry.npmjs.org/ \
    && npm config set fetch-retries 5 \
    && npm config set fetch-retry-factor 2 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm install --legacy-peer-deps \
    && mkdir -p public \
    && cp -r node_modules/monaco-editor public/ \
    && REACT_APP_MONACO_EDITOR_USING_CDN=false REACT_APP_ENABLE_ERRORS_INSPECTOR=true npm run build

FROM nginx:1.27-alpine

COPY docker/conductor-ui/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/ui/build /usr/share/nginx/html

EXPOSE 5000
