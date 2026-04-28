# Caddy with the static site baked in.
# Build context is `app/` so we can COPY web/ from a sibling dir:
#   docker build -t caddy-app:<sha> -f app/caddy-app/Dockerfile app/

FROM caddy:2.8-alpine

COPY web/ /srv/web/
