ARG DOCKER_IMAGE_PREFIX=docker.io
ARG CONDUCTOR_VERSION=3.22.3

FROM ${DOCKER_IMAGE_PREFIX}/azul/zulu-openjdk-debian:21 AS builder

ARG CONDUCTOR_VERSION

WORKDIR /conductor

COPY generated/conductor-source/conductor-source.tar.gz /tmp/conductor-source.tar.gz

RUN tar -xzf /tmp/conductor-source.tar.gz --strip-components=1 -C /conductor \
    && rm -f /tmp/conductor-source.tar.gz \
    && ./gradlew :conductor-server:bootJar \
      -x test \
      -x spotlessCheck \
      -x shadowJar \
      -x :conductor-os-persistence-v3:build \
      -PindexingBackend=opensearch \
      -Dorg.gradle.jvmargs=-Xmx2g \
      --no-daemon \
      --no-parallel

FROM ${DOCKER_IMAGE_PREFIX}/library/debian:stable-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openjdk-21-jre-headless ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app/config /app/logs /app/libs

COPY --from=builder /conductor/server/build/libs/*boot*.jar /app/libs/conductor-server.jar
COPY docker/conductor-server/startup.sh /app/startup.sh

RUN chmod +x /app/startup.sh

WORKDIR /app/libs

CMD ["/app/startup.sh"]
