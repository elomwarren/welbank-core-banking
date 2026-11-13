# WEL Bank web image: build the SvelteKit app, then let Caddy serve it and proxy /api.
# Build context: the repository root (see .dockerignore: only frontend/ and deploy/ are sent).
FROM node:24-alpine AS build
WORKDIR /src
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

FROM caddy:2-alpine
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /src/build /srv
