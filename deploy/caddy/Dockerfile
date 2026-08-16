# Caddy with the rate limiting module compiled in.
#
# Stock Caddy has no `rate_limit` directive — it lives in a third party module,
# and adding a module to Caddy means rebuilding the binary. That is what this
# image does, and it is the only reason it exists: everything else in the
# Caddyfile works with the official image.
#
# To run stock Caddy instead, comment the `rate_limit` block out of the
# Caddyfile and point compose.prod.yaml at `caddy:2-alpine`. The application's
# own limiter still counts sign in attempts by address and by account; what is
# lost is refusing them before they reach the app.

ARG CADDY_VERSION=2.10

FROM caddy:${CADDY_VERSION}-builder AS builder

# Pinned rather than left floating: a proxy that fetches whatever is newest at
# build time is a supply chain decision nobody made on purpose.
RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@v0.1.0

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
