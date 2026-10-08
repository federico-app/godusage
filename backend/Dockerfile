# The teams backend as a Node server on SQLite, for Coolify (see docs/teams-backend.md).
# Build context: this directory (backend/). Mount a volume at /data: it holds the database.
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run typecheck && npm run build:server

FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8787 \
    DATABASE_PATH=/data/godusage.db
COPY --from=build /app/dist/server.mjs ./server.mjs
COPY migrations ./migrations
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://127.0.0.1:8787/v1/health || exit 1
CMD ["node", "server.mjs"]
