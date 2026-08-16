🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Production deployment](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Production-deployment)
***

# Production deployment

## Menu

- [TLS](#tls)
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

---

Next: [Security](Administration-%E2%80%90-Security) ·
[Backups](Administration-%E2%80%90-Backups) ·
[Configuration](Administration-%E2%80%90-Configuration)
