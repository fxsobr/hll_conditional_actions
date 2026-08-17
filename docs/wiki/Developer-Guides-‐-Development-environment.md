🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Developer Guides / [Development environment](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment)
***

# Development environment

## Menu

- [With Docker (nothing to install)](#with-docker-nothing-to-install)
- [Without Docker](#without-docker)
- [Moving a port](#moving-a-port)
- [Useful commands](#useful-commands)

***

## With Docker (nothing to install)

```bash
docker compose up
```

Postgres, migrations, seeds and the server with code reloading, on
<http://localhost:4000>.

No configuration file is needed. The development stack has working defaults
built in, and `.env` — which is the **production** file — cannot reach it: every
variable the dev stack reads is prefixed `DEV_`.

## Without Docker

Requires Elixir 1.17+, OTP 26+ and a PostgreSQL you can reach.

```bash
mix setup
mix phx.server
```

## Moving a port

Only if something on your machine already holds 4000 or 5432:

```bash
cp .env.dev.example .env.dev
# edit DEV_APP_PORT / DEV_POSTGRES_PORT
docker compose --env-file .env.dev up
```

The `--env-file` matters. Compose reads `.env` by itself, and `.env` belongs to
production; naming this one explicitly is what keeps them apart.

## Useful commands

```bash
mix test                  # the full suite
mix test --failed         # only what failed last time
mix precommit             # compile with warnings as errors, format, test
mix ecto.reset            # drop, create, migrate, seed
```

---

See also [Translations](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Translations).
