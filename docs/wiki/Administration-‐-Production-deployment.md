🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Production deployment](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Production-deployment)
***

# Production deployment

## Menu

- [How it is served](#how-it-is-served)
- [Health probes](#health-probes)
- [Running migrations on their own](#running-migrations-on-their-own)

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

## How it is served

Caddy answers on **APP_PORT (4000) over plain HTTP** and proxies to the app.
It binds that and nothing else: ports 80 and 443 are left alone, so this never
collides with CRCON (8010 / 9010) or with anything else on the machine.

Only Caddy is published. The app and its PostgreSQL are reachable on the
compose network and nowhere else.

Caddy is still worth having in front of the app: it refuses a flood of sign in
attempts before they reach a BEAM process, and it compresses responses.

### TLS

There is none by default, and nothing asks Let's Encrypt for a certificate.
Plain HTTP is fine on a private network and not fine on the open internet.

To put TLS in front, either:

- **Terminate it elsewhere** — a proxy you already run, or Cloudflare — and set
  `FORCE_HTTPS=true` in `.env`. That marks the session cookie `secure` and
  redirects plain HTTP.
- **Let Caddy do it**: set `SITE_ADDRESS` to a hostname that resolves here,
  publish 80 and 443 instead of 4000 in `compose.prod.yaml` (the lines are
  there, commented), uncomment the HSTS header in the Caddyfile, and set
  `FORCE_HTTPS=true`.

> [!WARNING]
> `FORCE_HTTPS=true` without real TLS in front breaks signing in. A `secure`
> cookie is never sent over plain HTTP, so the login form accepts the password
> and returns you to itself with nothing to explain why.

## Health probes

| Path | Meaning |
| --- | --- |
| `GET /health` | The web process is up |
| `GET /health/ready` | The database answers too |

## Running migrations on their own

```bash
docker compose -f compose.prod.yaml run --rm app /app/bin/migrate
```

---

Next: [Security](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Security) ·
[Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups) ·
[Configuration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Configuration)
