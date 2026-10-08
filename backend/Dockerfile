# The teams backend: a Node server on Postgres and Redis, run by Coolify from docker-compose.yml (see
# docs/teams-backend.md). Build context: this directory (backend/).
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
RUN npm ci
COPY . .
RUN npm run typecheck && npm run build:server

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8787
# One bundled file (dependencies included) and the Postgres migrations it applies at startup.
COPY --from=build /app/dist/server.mjs ./server.mjs
COPY migrations ./migrations
USER node
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD wget -qO- http://127.0.0.1:8787/v1/health || exit 1
CMD ["node", "server.mjs"]
