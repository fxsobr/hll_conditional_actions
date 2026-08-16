🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Developer Guides / [Development environment](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment)
***

# Development environment

## Menu

- [With Docker (nothing to install)](#with-docker-nothing-to-install)
- [Without Docker](#without-docker)
- [Useful commands](#useful-commands)

***

## With Docker (nothing to install)

```bash
docker compose up
```

Postgres, migrations, seeds and the server with code reloading, on
<http://localhost:4000>.

## Without Docker

Requires Elixir 1.17+, OTP 26+ and a PostgreSQL you can reach.

```bash
mix setup
mix phx.server
```

## Useful commands

```bash
mix test                  # the full suite
mix test --failed         # only what failed last time
mix precommit             # compile with warnings as errors, format, test
mix ecto.reset            # drop, create, migrate, seed
```

---

See also [Translations](Developer-Guides-%E2%80%90-Translations).
