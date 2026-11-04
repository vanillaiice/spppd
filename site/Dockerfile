# The website, built from the repository root (see the root .dockerignore):
#   docker build -f site/Dockerfile .
# It reads README.md, CHANGELOG.md, PRIVACY.md, TERMS.md and src/config.lua from the repository,
# and serves the release builds that `make site-downloads` put in site/public/download.
FROM node:24-alpine AS build
WORKDIR /repo
COPY site/package.json site/package-lock.json site/
RUN cd site && npm ci
COPY README.md CHANGELOG.md PRIVACY.md TERMS.md ./
COPY src/config.lua src/
COPY site site
RUN cd site && npm run build

FROM caddy:2.11.6-alpine
COPY site/Caddyfile /etc/caddy/Caddyfile
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
COPY --from=build /repo/site/dist /srv
