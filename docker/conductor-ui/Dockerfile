ARG DOCKER_IMAGE_PREFIX=docker.io
ARG CONDUCTOR_VERSION=3.22.3

FROM ${DOCKER_IMAGE_PREFIX}/library/node:24.14.1-bookworm-slim AS builder

ARG CONDUCTOR_VERSION

WORKDIR /src

COPY generated/conductor-source/conductor-source.tar.gz /tmp/conductor-source.tar.gz

RUN tar -xzf /tmp/conductor-source.tar.gz --strip-components=1 \
    && rm -f /tmp/conductor-source.tar.gz

WORKDIR /src/ui

ENV CYPRESS_INSTALL_BINARY=0

RUN npm config set registry https://registry.npmmirror.com \
    && npm config set fetch-retries 5 \
    && npm config set fetch-retry-factor 2 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm install --legacy-peer-deps \
    && mkdir -p public \
    && cp -r node_modules/monaco-editor public/ \
    && REACT_APP_MONACO_EDITOR_USING_CDN=false REACT_APP_ENABLE_ERRORS_INSPECTOR=true npm run build

FROM ${DOCKER_IMAGE_PREFIX}/library/nginx:1.28.3-alpine

COPY docker/conductor-ui/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/ui/build /usr/share/nginx/html

EXPOSE 5000
