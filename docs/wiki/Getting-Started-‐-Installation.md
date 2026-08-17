🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Getting Started / [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation)
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
  - [Alternative: no Caddy, straight on its own port](#alternative-no-caddy-straight-on-its-own-port)
- [6. Sign in and change the password](#6-sign-in-and-change-the-password)
- [7. Connect your CRCON](#7-connect-your-crcon)
- [8. Write your first rule](#8-write-your-first-rule)
- [Updating](#updating)
- [Stopping and removing](#stopping-and-removing)
- [If something goes wrong](#if-something-goes-wrong)

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
| `PHX_HOST` | The hostname people will type — `rules.myclan.gg`. Leave `localhost` to try it out first |
| `ACME_EMAIL` | Your email, for certificate expiry warnings |
| `POSTGRES_PASSWORD` | Any long random string. Nothing but the app ever types it |
| `HTTP_PORT` / `HTTPS_PORT` | Only if 80 and 443 are already taken |
| `DEFAULT_LOCALE` | `pt_BR` for Portuguese |

The file explains each one where it sits. Ctrl+O, Enter, Ctrl+X to save in
nano.

> [!TIP]
> For a real certificate, `PHX_HOST` has to be a name that **resolves to this
> machine**, and port 80 has to be reachable from the internet — that is how
> Let's Encrypt validates it. Point an `A` record at the server first.

## 4. Generate the two secrets

Both are empty in the template and the stack refuses to start without them.

```bash
# SECRET_KEY_BASE — signs session cookies
docker run --rm hexpm/elixir:1.20.3-erlang-29.0.5-debian-trixie-20260803-slim \
  mix phx.gen.secret

# ENCRYPTION_KEY — encrypts the CRCON API keys in the database
openssl rand -base64 32
```

Paste each into `.env`.

> [!WARNING]
> **Keep a copy of `ENCRYPTION_KEY` somewhere other than this machine.** The
> database survives losing it; the CRCON keys inside it do not, and every
> server has to be entered again.

## 5. Start it

```bash
docker compose -f compose.prod.yaml up -d --build
```

The first build takes a few minutes — it compiles the release. After that,
starts are quick.

This brings up three containers: the app, its PostgreSQL, and **Caddy**, which
answers on 80 and 443 and gets the certificate by itself. Only Caddy is
published; the app and the database are reachable on the compose network and
nowhere else, so nobody can go around the sign in form by talking to port 4000.

### Does this fight with CRCON?

No. CRCON's own web container answers on **8010** and **9010**, not on 80 and
443, and its PostgreSQL and Redis are not published to the machine at all —
they live on CRCON's Docker network. This stack does the same with its own
database. The two never see each other.

| | CRCON | This app |
| --- | --- | --- |
| Web, HTTP | 8010 | 80 |
| Web, HTTPS | 9010 | 443 |
| Public stats | 7010 / 7011 | — |
| PostgreSQL | its own, not published | its own, not published |

If something *else* on the machine already holds 80 and 443 — your own reverse
proxy, another site — change `HTTP_PORT` and `HTTPS_PORT` in `.env` rather than
reaching for the alternative below.

> [!WARNING]
> Do not point this app at CRCON's database. It shares no schema with it, and
> nothing good comes of trying.

### Alternative: no Caddy, straight on its own port

If you would rather not run Caddy — something else already terminates TLS, or
the app is only reachable over a private network — there is a second compose
file:

```bash
docker compose -f compose.prod.direct.yaml up -d --build
```

Same release image, no proxy: the app answers on `APP_PORT` (4000 by default)
over **plain HTTP**, the way CRCON's own web container answers on 8010.

What changes is one variable, `BEHIND_PROXY=false`, and it matters more than it
looks:

| | Behind Caddy (default) | Direct |
| --- | --- | --- |
| Plain HTTP | redirected to https | served |
| Session cookie | `secure` | not `secure` |
| `X-Forwarded-For` | believed | ignored |
| HSTS | sent | not sent |

The cookie is the one that bites. A `secure` cookie is **never sent over plain
HTTP**, so running the default settings on a bare port produces an app where
signing in appears to work and then quietly does not — you land back on the
login page with nothing to explain it. That is why this is a separate compose
file rather than "just change the port".

> [!WARNING]
> Direct mode is plain HTTP. Passwords and session cookies travel in clear,
> and nothing refuses a flood before it reaches the application. On the open
> internet, put a proxy in front of it or use `compose.prod.yaml`, which gets a
> certificate by itself.

Check it came up:

```bash
docker compose -f compose.prod.yaml ps
docker compose -f compose.prod.yaml logs -f app
```

You are looking for `Running HllConditionalActionsWeb.Endpoint`. Ctrl+C stops
following the logs; it does not stop the app.

## 6. Sign in and change the password

Open `https://<your PHX_HOST>`. On `localhost`, or before DNS has caught up,
the browser will warn about the certificate — that is expected, continue.

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

```bash
cd ~/hll_conditional_actions
git pull
docker compose -f compose.prod.yaml up -d --build
```

Migrations run automatically before the new version serves any traffic. Your
data, your rules and your settings are in the `db_data` volume and are not
touched by a rebuild.

## Stopping and removing

```bash
# Stop, keep everything
docker compose -f compose.prod.yaml down

# Stop and delete the database as well. There is no undo
docker compose -f compose.prod.yaml down -v
```

## If something goes wrong

```bash
docker compose -f compose.prod.yaml logs app
docker compose -f compose.prod.yaml logs caddy
docker compose -f compose.prod.yaml logs db

# On the direct stack, same thing without the caddy line:
docker compose -f compose.prod.direct.yaml logs app
```

| Symptom | Usually |
| --- | --- |
| `set SECRET_KEY_BASE in .env` on startup | One of the two secrets is still empty |
| The browser cannot reach it at all | `HTTP_PORT`/`HTTPS_PORT` are taken, or a firewall. `sudo ss -tlnp \| grep -E ':(80\|443)'` |
| Certificate never arrives | `PHX_HOST` does not resolve to this machine, or port 80 is not reachable from the internet |
| The connection test cannot reach CRCON | The URL is `localhost`, which inside a container means the container. Use `host.docker.internal` or the machine's address |
| Sign in returns to the login page with no error | Running on a bare port with the default settings. The session cookie is `secure` and never leaves the browser over plain HTTP — use `compose.prod.direct.yaml` |
| Connected, but no rule ever fires | The log stream is off in CRCON |

More on all of these:
[Common issues](https://github.com/fxsobr/hll_conditional_actions/wiki/Troubleshooting-%E2%80%90-Common-issues).
