ARG DOCKER_IMAGE_PREFIX=docker.randallanjie.com
FROM ${DOCKER_IMAGE_PREFIX}/library/node:24.14.1-bookworm-slim AS build

WORKDIR /app

COPY workers/func2-ts/package.json /app/package.json
COPY workers/func2-ts/tsconfig.json /app/tsconfig.json
COPY workers/func2-ts/src /app/src

RUN npm config set registry https://registry.npmmirror.com \
    && npm install \
    && npm run build \
    && npm prune --omit=dev

FROM ${DOCKER_IMAGE_PREFIX}/library/node:24.14.1-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production

COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist

CMD ["node", "dist/main.js"]
