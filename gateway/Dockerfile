ARG DOCKER_IMAGE_PREFIX=docker.randallanjie.com
FROM ${DOCKER_IMAGE_PREFIX}/library/nginx:1.28.3-alpine

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories \
    && apk add --no-cache bash curl jq

COPY gateway/entrypoint.sh /entrypoint.sh
COPY gateway/nginx.template.conf /etc/nginx/templates/default.conf.template

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
