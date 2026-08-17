🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [Upgrading](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Upgrading)
***

# Upgrading

## Menu

- [The short version](#the-short-version)
- [How the version gets picked](#how-the-version-gets-picked)
- [Building it yourself instead](#building-it-yourself-instead)
- [What an upgrade touches, and what it leaves alone](#what-an-upgrade-touches)
- [Checking it worked](#checking-it-worked)
- [If it will not start](#if-it-will-not-start)
- [Going back](#going-back)
- [Following a tag, or following main](#following-a-tag-or-following-main)
- [If the pull is denied](#if-the-pull-is-denied)
- [CRCON is not involved](#crcon-is-not-involved)

***

## The short version

```bash
cd ~/hll_conditional_actions
git fetch --tags
git checkout v0.2.0
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d
```

Replace `v0.2.0` with the version you are moving to. The
[releases page](https://github.com/fxsobr/hll_conditional_actions/releases)
lists them, and the **About** dialog in the app tells you when there is a
newer one.

Nothing is compiled on your machine. The images are built when a release is
published and downloaded ready to run, so an upgrade takes about as long as
the download.

## How the version gets picked

Worth understanding, because it explains why the `git checkout` matters even
though no code is being compiled.

The compose file names the image with the version **it** was released as:

```yaml
image: ghcr.io/fxsobr/hll_conditional_actions:${APP_VERSION:-v0.2.0}
```

So checking out the tag is what selects the image. `pull` then fetches exactly
that one, and `up -d` runs it. There is no `latest` involved and nothing moves
under you: two servers on the same tag run the identical image.

To run a different version without moving the working copy, set `APP_VERSION`
in your `.env`. Useful for trying a version briefly, but the checkout is the
normal way, because it keeps the compose file and the image in step.

## Building it yourself instead

The published images are `linux/amd64`. On anything else — an ARM server, for
instance — or to run a commit that has not been released, build from source:

```bash
BUILD_VERSION=$(git describe --tags --always) \
  docker compose -f compose.prod.yaml up -d --build
```

The `build:` section is still in the compose file for exactly this. The
`BUILD_VERSION` part stamps the commit into the image so the About dialog
reports it; leave it out and everything still works, you just lose the ability
to tell two builds apart.

> [!NOTE]
> `--build` and `pull` do not mix. If you build locally and later run `pull`,
> the downloaded image replaces yours under the same name.

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

If the two disagree, the old image is still running — usually because
`pull` failed and `up -d` fell back to what was already there. The output of
the `pull` says why; a `denied` or `not found` almost always means the
[package is still private](#if-the-pull-is-denied).

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
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d
```

Older images are not deleted when a new one is published, so going back is
always a download away.

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

## If the pull is denied

```
Error response from daemon: denied
```

The images live in GitHub's registry and have to be public for an anonymous
`docker compose pull` to reach them. A package is **private when it is first
published**, and making it public is a one-off setting on the repository, not
something the release process can do:

**Repository → Packages → the package → Package settings → Change visibility →
Public.**

Once for each of the two packages, and never again.

If the images are private on purpose, sign in on the server first:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
```

## CRCON is not involved

Upgrading this app does not touch your CRCON in any way. They are separate
installations with separate databases and separate containers; this one talks
to yours over its API, like any other client.

You can upgrade either one without the other. If a CRCON upgrade ever changes
something this app depends on, that shows up as a connection or permission
error on the **Servers** page, not as a failed upgrade here.

***

**←** [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation) · **↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started)
