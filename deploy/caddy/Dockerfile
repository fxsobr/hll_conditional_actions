# Caddy with the rate limiting module compiled in.
#
# Stock Caddy has no `rate_limit` directive — it lives in a third party module,
# and adding a module to Caddy means rebuilding the binary. That is one of the
# two reasons this image exists.
#
# The other is the port list. The official `caddy` image declares
# `EXPOSE 80 443 2019 443/udp`, and that metadata travels with the image
# whether or not anything is listening: `docker ps` shows all four, which is
# noise at best and misleading at worst, since this deployment serves 4000 and
# nothing else. EXPOSE cannot be undone by a child image, so the final stage
# starts from plain alpine and takes only the binary.

ARG CADDY_VERSION=2.10

FROM caddy:${CADDY_VERSION}-builder AS builder

# Pinned rather than left floating: a proxy that fetches whatever is newest at
# build time is a supply chain decision nobody made on purpose.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@v0.1.0

FROM alpine:3.21

# The trust store, for anything Caddy fetches over TLS.
RUN apk add --no-cache ca-certificates

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# The paths the official image sets up, kept so a Caddyfile written for it
# still behaves the same way.
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

RUN mkdir -p /config/caddy /data/caddy

# No EXPOSE. What this listens on is decided by the Caddyfile, and published by
# compose.prod.yaml.

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
