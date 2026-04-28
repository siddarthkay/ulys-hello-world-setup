# Canary orchestrator + compose files + Caddyfile template, baked into one
# image. Run with /var/run/docker.sock, /opt/app/state, /opt/app/caddy bind
# mounts so it can talk to the host docker daemon.

FROM docker:25-cli

RUN apk add --no-cache bash curl jq tini

WORKDIR /opt/deploy

COPY compose.infra.yml compose.app.yml deploy.sh ./
COPY caddy/Caddyfile.tmpl ./caddy/Caddyfile.tmpl

RUN chmod +x /opt/deploy/deploy.sh

ENTRYPOINT ["/sbin/tini", "--", "/opt/deploy/deploy.sh"]
