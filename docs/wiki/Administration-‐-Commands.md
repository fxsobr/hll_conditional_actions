🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Administration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration) / [Commands](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Commands)
***

# Commands

Every command you are likely to need, in one place. Each one is run from the
project directory on the machine that hosts the app:

```bash
cd ~/hll_conditional_actions
```

## Menu

- [Running the service](#running-the-service)
- [Logs and status](#logs-and-status)
- [Upgrading and going back](#upgrading-and-going-back)
- [Backups](#backups)
- [The app's console](#the-apps-console)
- [Development](#development)

***

## Running the service

The stack is three containers: `app`, `db` (PostgreSQL) and `caddy` (the
only one published, on port 4000).

```bash
docker compose pull          # download the images of the checked out version
docker compose up -d         # start everything in the background
docker compose restart app   # restart only the app, e.g. after editing .env
docker compose down          # stop everything, keep the data
docker compose down -v       # stop and DELETE the database. There is no undo
```

After editing `.env`, `restart` is not enough for variables compose reads
itself — recreate the container instead:

```bash
docker compose up -d --force-recreate app
```

To serve the pages without connecting to any CRCON server (a second web node,
or reading production data while debugging), set `ENGINE_ENABLED=false` in
`.env` and recreate the app. See
[Configuration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Configuration).

## Logs and status

```bash
docker compose ps                   # what is running, and whether it is healthy
docker compose logs -f app          # follow the app (Ctrl+C stops following)
docker compose logs --tail 200 app  # the last 200 lines
docker compose logs caddy
docker compose logs db
```

Always by **service name** (`app`), never by container id: the id changes on
every upgrade.

## Upgrading and going back

```bash
git fetch --tags
git checkout v0.3.0          # the version you are moving to
docker compose pull
docker compose up -d
```

Migrations run by themselves before the new version serves traffic. Take a
backup first. The whole story, including undoing a migration, is on
[Upgrading](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Upgrading).

Which version is running:

```bash
git describe --tags
docker compose images app
```

## Backups

```bash
# Dump
docker compose exec -T db pg_dump -U "$POSTGRES_USER" hll_conditional_actions \
  | gzip > backup-$(date +%F).sql.gz

# Restore into an empty database (stop the app first so nothing writes)
docker compose stop app
gunzip -c backup-2026-09-28.sql.gz \
  | docker compose exec -T db psql -U "$POSTGRES_USER" hll_conditional_actions
docker compose start app
```

Keep `.env` — above all `ENCRYPTION_KEY` — somewhere other than this disk.
More on [Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups).

## The app's console

The release inside the `app` container answers two kinds of command.

A one-off expression, which runs and exits:

```bash
docker compose exec app /app/bin/hll_conditional_actions eval \
  'HllConditionalActions.Release.migrate()'
```

An interactive shell attached to the running app, for when you need to look
around (Ctrl+C twice to leave; the app keeps running):

```bash
docker compose exec app /app/bin/hll_conditional_actions remote
```

A few things worth knowing how to do from `remote`:

```elixir
# Which modules each server has installed
alias HllConditionalActions.{Features, Servers}
for s <- Servers.list_servers(), do: {s.name, Features.installed(s.id)}

# Install a module on every server at once
for s <- Servers.list_servers(), do: Features.install(s.id, :tickets)
```

Losing access to a second factor has its own procedure, on
[Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor).

## Development

With Docker, nothing else installed:

```bash
docker compose -f compose.dev.yaml up        # http://localhost:4000, with code reloading
docker compose -f compose.dev.yaml down
```

With Elixir and PostgreSQL installed locally:

```bash
mix setup                 # deps, database, migrations, seeds, assets
mix phx.server            # http://localhost:4000
iex -S mix phx.server     # the same, with a shell into it
mix test                  # the full suite
mix test --failed         # only what failed last time
mix precommit             # what CI checks: warnings, format, credo, tests
mix ecto.migrate          # apply new migrations
mix ecto.reset            # drop, create, migrate and seed the dev database
mix gettext.extract --merge   # after adding user-facing text
```

The first sign in on a fresh database is `admin` / `admin`, and it asks for a
new password straight away.

More on [Development environment](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment).

***

**←** [Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups) · **↑** [Administration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration)
