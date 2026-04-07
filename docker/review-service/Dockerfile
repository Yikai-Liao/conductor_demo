FROM node:22-bookworm-slim AS build

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

WORKDIR /app

COPY services/review-service/package.json /app/package.json
COPY services/review-service/tsconfig.json /app/tsconfig.json
COPY services/review-service/src /app/src

RUN npm config set registry https://registry.npmmirror.com \
    && npm install \
    && npm run build \
    && npm prune --omit=dev

FROM node:22-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production

COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/dist /app/dist

CMD ["node", "dist/main.js"]
