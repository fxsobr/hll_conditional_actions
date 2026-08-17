🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Production deployment](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Production-deployment)
***

# Production deployment

## Menu

- [TLS](#tls)
- [Health probes](#health-probes)
- [Running migrations on their own](#running-migrations-on-their-own)
- [Without a reverse proxy](#without-a-reverse-proxy)

***

```bash
cp .env.example .env
# fill in PHX_HOST, SECRET_KEY_BASE, ENCRYPTION_KEY, POSTGRES_PASSWORD
docker compose -f compose.prod.yaml up -d --build
```

This builds a release image (`Dockerfile`), runs migrations before serving any
traffic, and publishes **only Caddy**. The app and Postgres are reachable on
the compose network and nowhere else, so nobody can go around the sign in form
by talking to port 4000.

## TLS

Caddy gets and renews the certificate itself. Point `PHX_HOST` at a hostname
that resolves to the machine, leave ports 80 and 443 free, and the first boot
fetches a Let's Encrypt certificate. `PHX_HOST=localhost` issues a local one
instead, which is what makes a laptop run work without ceremony.

The certificate lives in the `caddy_data` volume. Keep it: losing it means
asking Let's Encrypt for a new one, and that is rate limited.

## Health probes

| Path | Meaning |
| --- | --- |
| `GET /health` | The web process is up |
| `GET /health/ready` | The database answers too |

## Running migrations on their own

```bash
docker compose -f compose.prod.yaml run --rm app /app/bin/migrate
```

## Without a reverse proxy

Caddy and CRCON's own nginx do not fight over anything — CRCON answers on
8010 and 9010, this stack on 80 and 443 — so running both is the normal
setup and needs nothing special.

If you would rather not run Caddy at all, because something else already
terminates TLS or because the app is only reachable over a private network,
there is a second compose file that publishes the app's own port instead:

```bash
docker compose -f compose.prod.direct.yaml up -d --build
```

It is the same release image. What changes is `BEHIND_PROXY=false`, which
turns off two things that would otherwise make the app unusable on plain HTTP:

| | Behind a proxy (default) | Direct |
| --- | --- | --- |
| Plain HTTP | redirected to https | served |
| Session cookie | `secure` | not `secure` |
| `X-Forwarded-For` | believed | ignored |
| HSTS | sent | not sent |

The cookie is the one that bites. A `secure` cookie is never sent over plain
HTTP, so with the default settings on port 4000 signing in appears to work and
then does not — you land back on the login page with no explanation.

> [!WARNING]
> Direct mode is **plain HTTP**. Passwords and session cookies travel in
> clear, and nothing refuses a flood before it reaches the application. On the
> open internet, put a proxy in front or use `compose.prod.yaml`, which gets a
> certificate by itself.

---

Next: [Security](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Security) ·
[Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups) ·
[Configuration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Configuration)
