🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation)
***

# Installation

## Menu

- [Before you start](#before-you-start)
- [1. Log into your server over SSH](#1-log-into-your-server-over-ssh)
- [2. Download the project](#2-download-the-project)
- [3. Create the configuration file](#3-create-the-configuration-file)
- [4. Generate the two secrets](#4-generate-the-two-secrets)
- [5. Start it](#5-start-it)
  - [Does this fight with CRCON?](#does-this-fight-with-crcon)
  - [About TLS](#about-tls)
- [6. Sign in and change the password](#6-sign-in-and-change-the-password)
- [7. Connect your CRCON](#7-connect-your-crcon)
- [8. Write your first rule](#8-write-your-first-rule)
- [Updating](#updating)
- [Stopping and removing](#stopping-and-removing)
- [If something goes wrong](#if-something-goes-wrong)
  - [Reading the logs](#reading-the-logs)
  - [Common causes](#common-causes)

***

## Before you start

You need:

- a machine with **Docker** and **Docker Compose** — the same VPS that runs
  CRCON is the normal choice
- a **working CRCON**, with an API key. If you do not have one yet, install
  CRCON first: [its installation guide](https://github.com/MarechJ/hll_rcon_tool/wiki/Getting-Started-%E2%80%90-Installation)
- about ten minutes

You do **not** need Elixir, PostgreSQL or anything else installed. The stack
brings its own.

Full detail on what is required, and on the CRCON side of it, is on
[Requirements](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements).

## 1. Log into your server over SSH

```bash
ssh user@your-server-address
```

If CRCON is already on this machine you are probably in the right place
already.

## 2. Download the project

Put it **beside** your CRCON directory, not inside it.

```bash
cd ~
git clone https://github.com/fxsobr/hll_conditional_actions.git
cd hll_conditional_actions
```

No git on the machine? `sudo apt update && sudo apt install -y git`.

## 3. Create the configuration file

```bash
cp .env.example .env
nano .env
```

Every value in that file already works except the two secrets. What is worth
changing:

| Variable | Change it to |
| --- | --- |
| `PHX_HOST` | How people reach the machine — a hostname, or its address |
| `APP_PORT` | Only if 4000 is already taken |
| `POSTGRES_PASSWORD` | Any long random string. Nothing but the app ever types it |
| `DEFAULT_LOCALE` | `pt_BR` for Portuguese |

The file explains each one where it sits. Ctrl+O, Enter, Ctrl+X to save in
nano.

## 4. Generate the two secrets

Both are empty in the template and the stack refuses to start without them.

```bash
# SECRET_KEY_BASE — signs session cookies. At least 64 characters
openssl rand -base64 64 | tr -d '\n'; echo

# ENCRYPTION_KEY — encrypts the CRCON API keys. Exactly 32 bytes
openssl rand -base64 32
```

Paste each into `.env`, on one line.

> [!NOTE]
> `openssl` is on any Debian or Ubuntu server already. `mix phx.gen.secret`
> would also work, but only inside a checkout with the dependencies
> installed — not in a bare Elixir container, which has no Phoenix in it.

> [!WARNING]
> **Keep a copy of `ENCRYPTION_KEY` somewhere other than this machine.** The
> database survives losing it; the CRCON keys inside it do not, and every
> server has to be entered again.

## 5. Start it

```bash
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d
```

The first build takes a few minutes — it compiles the release. After that,
starts are quick.

This brings up three containers: the app, its PostgreSQL, and **Caddy**, which
answers on **port 4000 over plain HTTP** and proxies to the app. Only Caddy is
published; the app and the database are reachable on the compose network and
nowhere else, so nobody can go around the sign in form by talking to the app
directly.

Open `http://<your machine>:4000`.

### Does this fight with CRCON?

No, and deliberately so. Caddy binds **4000 and nothing else** — ports 80 and
443 are left alone, so anything you already run there is untouched. CRCON's own
web container answers on 8010 and 9010, and both stacks keep their PostgreSQL
on their own Docker network without publishing it.

| | CRCON | This app |
| --- | --- | --- |
| Web | 8010 / 9010 | **4000** |
| Public stats | 7010 / 7011 | — |
| PostgreSQL | its own, not published | its own, not published |

Change `APP_PORT` in `.env` if 4000 itself is taken.

> [!WARNING]
> Do not point this app at CRCON's database. It shares no schema with it, and
> nothing good comes of trying.

### About TLS

Port 4000 is **plain HTTP**. Passwords and session cookies travel in clear, so:

- on a private network, or reachable only through a VPN, this is fine as it is
- on the open internet, put something in front that terminates TLS — a proxy
  you already run, or Cloudflare — and then set `FORCE_HTTPS=true` in `.env`

That flag marks the session cookie `secure` and redirects plain HTTP. Setting
it **without** real TLS in front breaks signing in: a `secure` cookie is never
sent over plain HTTP, so the login form accepts the password and returns you to
itself with nothing to explain why.

## 6. Sign in and change the password

Open `http://<your machine>:4000`.

The first account is:

```
admin
admin
```

You are asked to choose a new password immediately, and the hint disappears
from the login page the moment you do.

> [!TIP]
> Create a second administrator account now, from **Users**. It is the way
> back in if you lock yourself out of the first one — especially once two
> factor is on.

## 7. Connect your CRCON

**Servers → Add server.**

| Field | What to put |
| --- | --- |
| **Name** | Whatever you call it. `Caveiras Brasil #1` |
| **Game** | Hell Let Loose, or Hell Let Loose: Vietnam |
| **CRCON URL** | `http://host.docker.internal:8010` when CRCON is on this same machine, otherwise its address. Not `localhost`: inside a container that is the container itself |
| **API key** | From CRCON: *Django admin → Django API Keys*. Create a key for a **regular** user, not a superuser |
| **Timezone** | Your players' timezone. Time-of-day conditions use it |

Then **Test the connection**. This is not optional — the server cannot be
saved until it passes, and it tells you exactly what is wrong when it does not.

It also refuses a **superuser** key on purpose. A superuser key bypasses every
permission check in CRCON, so a leak of this app's database would hand over the
game server entirely. Create a regular CRCON user, grant it only the
permissions the test lists, and issue a key for that.

The permissions you need depend on the actions your rules use.
`can_view_structured_logs` is always required — without it there are no events
at all. See
[Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server).

Also turn on the log stream in CRCON, under *Settings → Others → Log Stream*,
with `enabled` set to `true`. It ships **disabled**, and without it CRCON
accepts the connection and then sends nothing.

## 8. Write your first rule

**Rules → Recipes** and pick *Welcome message*. It opens in the builder already
filled in and **in simulation**, so it records what it would have sent without
touching the game.

Save it, let a few players connect, then open the rule and read its **History**.
When you are happy, edit it and turn **Simulation only** off.

From there: [Writing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules).

## Updating

Migrations run automatically before the new version serves any traffic, and
your data, rules and settings are in the `db_data` volume, untouched by a
rebuild.

The commands, the one step people skip, and how to get back if an upgrade
goes badly: [Upgrading](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Upgrading).

## Stopping and removing

```bash
# Stop, keep everything
docker compose -f compose.prod.yaml down

# Stop and delete the database as well. There is no undo
docker compose -f compose.prod.yaml down -v
```

## If something goes wrong

### Reading the logs

From the project directory, and by **service name** rather than by container
id — the id changes on every rebuild:

```bash
cd ~/hll_conditional_actions

docker compose -f compose.prod.yaml logs -f app        # follow the app
docker compose -f compose.prod.yaml logs --tail 200 app
docker compose -f compose.prod.yaml logs caddy
docker compose -f compose.prod.yaml logs db
docker compose -f compose.prod.yaml logs               # all three
```

`-f` follows the log as it is written; Ctrl+C stops following and leaves the
container running.

`docker logs <id>` works too, but you have to look the id up first
(`docker compose -f compose.prod.yaml ps`) and it will be a different one after
the next upgrade.

### Common causes

| Symptom | Usually |
| --- | --- |
| `/app/bin/migrate: Permission denied`, repeating | Only affects images built from a checkout that lost the executable bit on the release scripts. Fixed since Aug 2026, and the published images never had it |
| `set SECRET_KEY_BASE in .env` on startup | One of the two secrets is still empty |
| The browser cannot reach it at all | `APP_PORT` is taken, or a firewall. `sudo ss -tlnp \| grep 4000` |
| The connection test cannot reach CRCON | The URL is `localhost`, which inside a container means the container. Use `host.docker.internal` or the machine's address |
| Sign in returns to the login page with no error | `FORCE_HTTPS=true` with no TLS actually in front. The session cookie is `secure` and never leaves the browser over plain HTTP |
| Connected, but no rule ever fires | The log stream is off in CRCON |

More on all of these:
[Common issues](https://github.com/fxsobr/hll_conditional_actions/wiki/Troubleshooting-%E2%80%90-Common-issues).

***

**←** [Requirements](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements) · **↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) · [Upgrading](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Upgrading) **→**
