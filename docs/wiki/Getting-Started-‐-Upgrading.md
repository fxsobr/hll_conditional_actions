🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [Upgrading](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Upgrading)
***

# Upgrading

## Menu

- [The short version](#the-short-version)
- [Why the rebuild is not optional](#why-the-rebuild-is-not-optional)
- [What an upgrade touches, and what it leaves alone](#what-an-upgrade-touches)
- [Checking it worked](#checking-it-worked)
- [If it will not start](#if-it-will-not-start)
- [Going back](#going-back)
- [Following a tag, or following main](#following-a-tag-or-following-main)
- [CRCON is not involved](#crcon-is-not-involved)

***

## The short version

```bash
cd ~/hll_conditional_actions
git fetch --tags
git checkout v0.2.0
BUILD_VERSION=$(git describe --tags --always) docker compose -f compose.prod.yaml up -d --build
```

Replace `v0.2.0` with the version you are moving to. The
[releases page](https://github.com/fxsobr/hll_conditional_actions/releases)
lists them, and the **About** dialog in the app tells you when there is a
newer one.

## Why the rebuild is not optional

This is the step people skip, so it is worth being blunt about.

This project **builds its image on your machine**. It does not publish a
prebuilt one, so there is nothing to `docker compose pull`. Without `--build`,
compose finds an image already there, decides it has nothing to do, and starts
the old version again.

Nothing warns you. The containers come up, the site answers, the logs look
normal — and you are still running the version you were trying to leave. The
only sign is that the version in the About dialog did not change.

The `BUILD_VERSION` part is what stamps the running commit into the image, so
the app can report `v0.2.0` instead of falling back to the version written in
`mix.exs`. Leave it out and everything still works; you just lose the ability
to tell two builds apart.

## What an upgrade touches

**Migrations run on their own.** The container starts with
`/app/bin/migrate && /app/bin/server`, so the database schema is brought up to
date *before* the new version answers a single request. If a migration fails,
the server does not start at all — which is the behaviour you want. A site
that is down is a problem you will fix; a site serving traffic against a
half-migrated schema is a problem you will find out about later, from your
players.

**Your data stays.** Rules, users, history and settings live in the `db_data`
volume. Rebuilding the image does not touch volumes.

**Your configuration stays.** `.env` is not in the repository, so
`git checkout` has nothing to say about it. Your secrets, your database
password and your CRCON settings survive the switch.

> [!IMPORTANT]
> Take a database backup before any upgrade that you would find painful to
> undo. It costs one command and it is the only thing that makes going back
> genuinely safe. See [Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups).

## Checking it worked

Open the **About** dialog — the version line at the bottom of the sidebar,
above your account — and compare it with what the server says:

```bash
git describe --tags --always
```

If the two disagree, you forgot `--build` and the old image is still running.

One thing to know: the dialog does not check GitHub on demand. It checks
thirty seconds after the app starts and every six hours after that, because
GitHub allows sixty unauthenticated requests an hour and spending them on page
views would exhaust them. Since an upgrade restarts the app anyway, the dialog
is accurate again within a minute of the upgrade finishing.

## If it will not start

```bash
docker compose -f compose.prod.yaml logs --tail 200 app
```

A failed migration is the usual cause and says so plainly. The database is
still on the old schema when a migration fails partway, so going back to the
previous version is normally enough to get running again — see below.

## Going back

Rolling the code back is easy. Rolling the database back is not, and the
difference is where people get hurt.

**Migrations do not undo themselves.** If you check out the older version and
rebuild, its `migrate` runs and does nothing — there is nothing new to apply.
But the schema is still the *new* one. If the version you are leaving added a
column that cannot be empty, the older code does not know to fill it, and it
breaks on the first write.

So the order matters. Undo the schema **first**, while the new version is
still running:

```bash
docker compose -f compose.prod.yaml exec app \
  /app/bin/hll_conditional_actions eval \
  'HllConditionalActions.Release.rollback(HllConditionalActions.Repo, 20260816223823)'
```

The number is the timestamp of the migration you want undone — that one and
everything after it are reversed. The filenames in `priv/repo/migrations/`
are those timestamps.

Then switch the code:

```bash
git checkout v0.1.0
BUILD_VERSION=$(git describe --tags --always) docker compose -f compose.prod.yaml up -d --build
```

> [!WARNING]
> **Undoing a migration does not bring data back.** If the migration you are
> reversing dropped a column, its `down` recreates that column empty. The
> values are gone.

Which is why, in practice, the safer route out of a bad upgrade is usually not
to reverse migrations at all: restore the dump you took beforehand and start
the older version against it. Reversing migrations is for when you have no
backup and no choice.

## Following a tag, or following main

`git checkout v0.2.0` leaves you in what git calls a detached HEAD. That is
the right state for a server: it pins you to exactly that commit, and nothing
moves under you.

To go back to following development instead:

```bash
git checkout main && git pull
```

`main` is where work lands as it is merged. It is not what a server should
usually run — a tag is a version somebody decided was ready, and `main` is
whatever was merged most recently.

## CRCON is not involved

Upgrading this app does not touch your CRCON in any way. They are separate
installations with separate databases and separate containers; this one talks
to yours over its API, like any other client.

You can upgrade either one without the other. If a CRCON upgrade ever changes
something this app depends on, that shows up as a connection or permission
error on the **Servers** page, not as a failed upgrade here.

***

**←** [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation) · **↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started)
