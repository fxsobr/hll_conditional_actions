# HLL Conditional Actions

Rule automation for Hell Let Loose servers, built on top of
**[CRCON](https://github.com/MarechJ/hll_rcon_tool)**.

Write rules in the shape *when **TRIGGER** happens, if **CONDITIONS** hold, run
**ACTIONS***, point the app at one or more CRCON deployments, and it reacts to
your servers in real time: welcoming new players, warning team killers,
escalating on repeat offenders, rewarding the people who seed, or posting to
Discord when something needs a human.

No scripting. A rule is built from dropdowns, reads back as a sentence, and can
be tried against a player who is connected right now — or left in simulation,
where it records everything it *would* have done without touching the game.

> [!IMPORTANT]
> **This app does not talk to Hell Let Loose. It talks to CRCON.**
>
> You need a working [CRCON](https://github.com/MarechJ/hll_rcon_tool)
> installation before this is of any use: it is what holds the RCON connection,
> parses the game logs and exposes both as an API. Without one there is nothing
> for this app to read from or act on.

Both games are supported and kept separate throughout: **HLL** (WW2) and
**HLLV** (Hell Let Loose: Vietnam) have different roles, teams, maps and game
modes, so a rule always declares which game it is written for.

---

## Screenshots

**Overview** — the servers, whether their log streams are live, and what the
rules have been doing.

![Overview](docs/screenshots/overview.png)

**The rule builder** — setup, trigger, conditions, actions and limits as steps,
with the rule reading back in plain words beside them.

![The rule builder](docs/screenshots/rule-builder.png)

**A rule's own page** — how often it fired, how many players it reached, what
failed, and every change ever made to it.

![A rule](docs/screenshots/rule.png)

---

## Table of contents

- [Screenshots](#screenshots)
- [How it connects to CRCON](#how-it-connects-to-crcon)
- [Quick start](#quick-start)
- [Configuring a server](#configuring-a-server)
- [Writing rules](#writing-rules)
- [Trying a rule before trusting it](#trying-a-rule-before-trusting-it)
- [Sharing rules](#sharing-rules)
- [Access control](#access-control)
- [Metrics](#observability)
- [Architecture](#architecture)
- [Environment variables](#environment-variables)
- [Development](#development)
- [Production](#production)
- [Two factor](#two-factor)
- [Backups](#backups)
- [Hardening notes](#hardening-notes)
- [Thanks](#thanks)

---

## How it connects to CRCON

CRCON is not modified, and no `hooks.py` patch is required. This app is an
ordinary API client, which means it keeps working across CRCON upgrades and can
drive several CRCON deployments from one place.

Two integration points are used:

| What | Endpoint | Used for |
| --- | --- | --- |
| REST API | `POST\|GET /api/<command>` with `Authorization: Bearer <api_key>` | Reading game state and players, running actions (message, punish, kick, ban, flag, broadcast, ...) |
| Log stream | `WebSocket /ws/logs` with the same bearer token | Real time game events: connects, kills, team kills, chat, match start/end |

The WebSocket path is what makes rules react instantly. CRCON pushes every
structured log line it parses, the app normalizes it
(`HllConditionalActions.Crcon.Events`) and the engine evaluates the rules that
subscribe to that trigger.

> **Why not `hooks.py`?**
> Patching CRCON's `rcon/hooks.py` couples this app to one CRCON install and to
> its Python version, and the patch has to be reapplied on every upgrade. The
> API and log stream are the supported, stable surface, and they are also what
> lets one instance of this app serve a whole fleet.

### Requirements on the CRCON side

1. A CRCON user with an **API key** (Django admin → *Django API Keys*).
2. That user needs the `can_view_structured_logs` permission, plus whatever the
   actions your rules use require (`can_message_players`, `can_punish_players`,
   `can_kick_players`, `can_temp_ban_players`, ...).
3. **The log stream turned on**, in CRCON under
   *Settings → Others → Log Stream*, with `enabled` set to `true`. It ships
   disabled, and without it CRCON accepts the WebSocket connection and then
   immediately refuses to send anything — the server shows up as *Error* on the
   dashboard with that explanation.

Creating a dedicated user for this app is recommended: CRCON records the API
key's owner as the author of every action, so its work shows up clearly in the
CRCON audit log.

---

## Quick start

```bash
cp .env.example .env
docker compose up
```

Then open <http://localhost:4000> and sign in with:

```
username: admin
password: admin
```

The app forces a new password on that first sign in.

---

## Configuring a server

**Servers → Add server**

| Field | Notes |
| --- | --- |
| Name | How the server appears throughout the UI |
| Game | `Hell Let Loose` or `Hell Let Loose: Vietnam` — decides the available roles, teams and game modes |
| Time zone | The community's IANA zone. Time-of-day conditions use it, so "after 22:00" means your players' evening |
| CRCON address | The base URL, e.g. `https://rcon.example.com` |
| API key | Stored encrypted (AES-GCM) and never shown again |
| Consume the live log stream | Turn off for a server you only want to act on with periodic rules |

Any number of servers can be registered, of either game, mixed freely.

### The connection test is mandatory

**Save stays disabled until Test connection passes.** The test calls
`get_own_user_permissions`, which needs authentication, so reaching it proves
the key is real — and its answer is checked against least privilege.

The key is refused when it:

- belongs to a **CRCON superuser** (superusers bypass every permission check,
  so the reported permission list means nothing)
- holds **any permission this app never calls** — the review names them so you
  can remove them
- is **missing `can_view_structured_logs`**, without which no event-triggered
  rule can ever fire

Missing *action* permissions are only a warning: the review lists which rule
actions would fail, and you can grant them later.

The reasoning is blunt: an API key is full control of a game server. If the key
stored here can also change server settings or manage admins, then a bug in
this app — or a leaked database — inherits all of it. Create a CRCON user for
this app alone and grant it only what the form lists.

Editing the URL or the key clears the approval, so the thing that was verified
is always the thing that gets saved.

---

## Writing rules

A rule has four parts.

### 1. When — the trigger

| Trigger | Fires |
| --- | --- |
| Player connects | Once, for that player, a few seconds later (see below) |
| Player disconnects | Once, for that player |
| Player gets a kill / dies / team kills | Once, for the player involved |
| Player writes in chat | Once, for the author |
| Player types a chat command | Once, for the author, when the message opens with `!`, `@` or `#` |
| Player switches team | Once, for that player |
| Match starts / ends | Once for **every** connected player |
| On a schedule | Every N seconds, for every connected player |

A single `KILL` log line fires both `player kill` (for the killer) and
`player dies` (for the victim), matching CRCON's own behaviour. A chat line
starting with a command prefix likewise fires both `player writes in chat` and
`player types a chat command` — the second one hands you the parsed `command`
(`!vip please` → `vip`) and `command arguments` (`please`) instead of making
you match the raw text.

**A connect is handled about five seconds late, on purpose.** When the game
server reports `CONNECTED`, the player does not exist in `get_detailed_players`
yet, so their level, clan tag, team and stats would all read as unavailable and
any condition on them would be false. Waiting is what makes a welcome rule fire
for everyone rather than for whoever happened to be in the last snapshot. Tune
it with `CONNECT_DELAY_MS` if your server is slower or faster.

### 2. If — the conditions

Conditions are `field operator value`, combined with **and**, **or**, **nand**
or **nor**. Fields cover the player (name, level, VIP, role, team, squad), the
squad and role (squad size, whether it has a leader, whether the player leads
it or commands, whether they are alone in an armor squad), the match (kills,
deaths, K/D, scores, per-minute rates, playtime), their history (sessions,
total playtime, penalties, flags), the server (player counts per team, how
lopsided the teams are, scores, map, game mode, time remaining) and the event
itself (chat message, command, weapon, other player).

The squad fields are read from the `get_detailed_players` snapshot the engine
already fetches each cycle — the same data CRCON builds its own team view
from — so a "squad without an officer" rule costs no extra API call.

Two things narrow the list as you build:

- **the trigger** — `weapon` only exists on a kill event, so it is not offered
  on a `player connects` rule (and is rejected if you try);
- **the game** — role, team and game mode values come from that game's profile,
  so a Vietnam rule offers `Squad Leader` and `Pilot` while a WW2 rule offers
  `Officer` and `Artillery Observer`.

Anything the current snapshot cannot answer evaluates to false. A rule never
fires on incomplete data, which matters when the action is a ban.

> **`Clan tag` is not the tag in the player's name.** It is the game's own
> clan tag field, which most players never set, so it is usually empty. If your
> community writes its tag into the player name (`ャ MadMax`), match on
> **`Player name`** instead — a `clan tag does not contain ャ` condition is true
> for everybody, because their clan tag is blank.

### 3. Then — the actions

Messaging (`message the player`, `message every player`, `set the broadcast`,
`broadcast temporarily`, `set the welcome screen`), punishment (`punish`,
`kick`, `temp ban`, `perma ban`, `switch team now`, `switch team on death`),
bookkeeping (`add`/`remove flag`, `add`/`remove from watchlist`) and
`send a Discord message`.

Any text field accepts placeholders, using the same syntax as CRCON's message
templates:

```
Welcome {player_name}! You are level {player_level} playing {player_role} on {map_name}.
```

Available: `player_name`, `player_id`, `player_level`, `player_role`, `team`,
`unit_name`, `clan_tag`, `kills`, `deaths`, `teamkills`, `combat`, `offense`,
`defense`, `support`, `is_vip`, `playtime_minutes`, `map_name`, `game_mode`,
`server_name`, `server_player_count`, `weapon`, `target_player_name`,
`message`.

An unknown placeholder is left visible in game rather than silently blanked, so
a typo is obvious.

### 4. Scope and limits

- **Applies to** — one specific server, or every enabled server of that game.
  One rule can cover a whole fleet.
- **Priority** — higher runs first.
- **Cooldown per player** — minimum seconds between two runs for the same
  player.
- **Maximum times per player per day** — a cap within a rolling 24 hour window.

Both limits use the `rule_executions` table, which is also the audit log you
browse under **History**.

### Trying a rule before trusting it

Two things make it safe to write a rule that kicks or bans.

**Try it** — at the bottom of the builder, pick a server and a player who is
connected right now. The rule *as currently typed*, unsaved edits included, is
evaluated against them and you get a table showing each condition's expected
value, its actual value, and whether it held. Nothing is sent to the game.

**Simulation** — a switch on the rule itself. A rule in simulation is
evaluated, rate limited and recorded in the history exactly as usual, with the
messages it *would* have sent rendered in full, but no call reaches CRCON.
Leave it on for a day, read the history, then switch it off.

### Time windows

`Hour of day` and `Day of the week` read the server's configured time zone, so
a rule follows your players' local time and daylight saving. A window that
crosses midnight is two conditions combined with **Any condition may hold**:
`hour ≥ 22` or `hour ≤ 2`.

### Sharing rules

**Export** downloads the rules currently listed (the filters apply) as JSON;
**Import** takes that file back. What travels is the rule itself — trigger,
conditions, actions, limits and game. What does not: the server it was pinned
to, since an id from another install means nothing, so the importer asks where
the rules should land.

Imported rules always arrive **disabled**. An invalid rule anywhere in the file
imports nothing at all, rather than leaving half a rule set behind.

### Example

> **Warn repeat team killers**
> *When* a player team kills · *if* team kills ≥ 3 **and** players on the server
> ≥ 40 · *then* message the player *"{player_name}, that is {teamkills} team
> kills. The next one is a kick."* and send a Discord message · cooldown 120s.

---

### Escalating repeat offenders

By default every action of a rule runs every time it fires. Set **escalate
repeat offenders** (in *Limits*) to a number of seconds and the action list
becomes a ladder instead: the engine counts how many times the rule already
fired for *that player* inside the window and runs only the matching step.

| Actions | 1st offence | 2nd | 3rd | 4th and beyond |
| --- | --- | --- | --- | --- |
| message, message, punish, kick | message | message | punish | kick |

Past the end of the list the last step repeats, so "…and keep kicking" needs
no special case. The count comes from the execution history rather than from
memory, so a restart does not hand a repeat offender a clean slate, and the
window rolls — stop offending for long enough and the ladder resets itself.

This is one rule, not four. The same count is also available as the
`times this rule already hit this player` condition, if you would rather
branch on it than escalate.

## Access control

Access is role based. A user has one role, and a role carries a list of
permissions:

| Permission | Grants |
| --- | --- |
| `view_servers` / `manage_servers` | See servers / add, edit and remove them |
| `view_rules` / `manage_rules` | See rules / create, edit and remove them |
| `view_executions` | Browse the rule history |
| `view_live_feed` | Watch the live event feed |
| `manage_users` | Manage user accounts |
| `manage_roles` | Manage roles and their permissions |

A `manage_*` permission implies the matching `view_*`.

### Server scope

The role says *what* an account may do; its server list says *where*. An
account with **no servers assigned reaches every server**, which is what a
single-community install wants and means nothing has to be configured.

Assign even one server and the account is confined to it: it sees only those
servers, their rules and their history. Fleet-wide rules that reach one of its
servers are visible but read only, since changing one would affect servers it
does not administer.

Three roles are seeded on first boot and cannot be deleted:

- **Administrator** — everything
- **Operator** — writes rules and watches what they do, but cannot touch server
  credentials or user access
- **Viewer** — read only

Every page is enforced server side through `on_mount` hooks, and every mutating
event re-checks the permission. Hiding a button in the sidebar is presentation,
not authorization.

---

## Architecture

```
lib/hll_conditional_actions/
├── games/                  Game profiles, one module per game
│   ├── hll.ex              Hell Let Loose (WW2): roles, teams, game modes
│   ├── hllv.ex             Hell Let Loose: Vietnam
│   └── profile.ex          The behaviour and struct they both implement
├── crcon/                  Everything that talks to CRCON
│   ├── client.ex           REST, bearer auth, envelope unwrapping
│   ├── log_stream.ex       WebSocket consumer with backoff (Mint.WebSocket)
│   └── events.ex           Raw log line → domain event
├── engine/                 The rule engine
│   ├── snapshot.ex         Cached players + game state, shared per cycle
│   ├── context.ex          What one rule is evaluated against
│   ├── evaluator.ex        Fields, operators, logical combination
│   ├── template.ex         {placeholder} rendering
│   ├── limiter.ex          Cooldown and per-player caps
│   ├── executor.ex         Runs the actions
│   └── runner.ex           One process per server, owns the periodic sweep
├── runtime.ex              Starts/stops a subtree per enabled server
├── servers.ex              CRCON deployments
├── rules.ex                Rules and execution history
└── accounts.ex             Users, roles, permissions
```

### The supervision tree

```
HllConditionalActions.Supervisor
├── Vault                     Encryption for stored API keys
├── Repo
├── Accounts.Bootstrap        Seeds roles + the first admin
├── Oban                      Background jobs (Postgres backed)
├── PubSub
├── Runtime.Registry
├── Runtime.ServerSupervisor  DynamicSupervisor
│   └── (one subtree per enabled server)
│       ├── Crcon.LogStream
│       └── Engine.Runner
├── Runtime                   Follows the database, starts/stops subtrees
└── Endpoint
```

A server that is unreachable only affects its own subtree; the rest of the
fleet keeps running.

### Where the work happens

- **Evaluation is cheap.** Every rule for one event shares a single CRCON
  snapshot (`get_detailed_players` + `get_gamestate`), cached for a few seconds.
  A busy firefight does not turn into an API flood.
- **In-game consequences run inline.** A kick that lands thirty seconds late
  punishes a situation that has already passed, so punishments are not queued.
- **Everything retryable goes through Oban.** Discord webhooks, restoring a
  temporary broadcast, pruning old history.
- **The audit row is written first.** It is what the cooldown check reads, so
  two events arriving back to back cannot both slip past the limit.

### Stack

Phoenix 1.8 · LiveView 1.2 · Tailwind CSS 4 + Petal Components · Alpine.js ·
Ecto/PostgreSQL · Oban · Caddy · TOTP two factor ·
Gettext (English + Brazilian Portuguese)

### Artwork

`login-art.webp` — the panel beside the sign in form — belongs to this
project. The rest are copied from CRCON, which ships them for its own login
and public pages:

| Here | From `hll_rcon_tool` |
| --- | --- |
| `banner.webp` | `assets/rcongui/login_banner.webp` |
| `map-carentan.webp` | `assets/images/maps/carentan-dusk.webp` |
| `map-stalingrad.webp` | `assets/images/maps/stalingrad-dusk.webp` |
| `map-foy.webp` | `assets/images/maps/foy-night.webp` |

Hell Let Loose is a trademark of Team17 / Expression Games. They are used here
for the same purpose CRCON uses them: decorating an admin tool for Hell Let
Loose server owners.

### Observability

**Monitoring → Metrics** is the built-in view, no external tooling required:
rule firings by outcome and how long their actions take, why rules were
skipped, game events by kind, log stream connection changes, and CRCON latency
per endpoint. Counters are cumulative since the node started, and the page is
the fastest way to answer "is anything reaching this app at all".

`/dev/dashboard` (development) shows the same data through
`Telemetry.metrics/0`:

| Metric | Tells you |
| --- | --- |
| `rule.fired` count and duration | Which rules fire, how often, and how long their actions take |
| `rule.skipped` count | Rules a trigger reached but that did not run, tagged with the reason (cooldown, conditions, caps) |
| `crcon.request` duration | CRCON round-trip latency by endpoint — the first place a struggling game server shows up |
| `log_stream.event` count | Game events received, by kind |
| `log_stream.status` count | Connection state changes per server |

To ship these elsewhere, attach a reporter (`telemetry_metrics_prometheus`,
`telemetry_metrics_statsd`) to `HllConditionalActionsWeb.Telemetry.metrics/0`.

---

## Environment variables

See [`.env.example`](.env.example) for the full list.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `DATABASE_URL` | prod | — | `ecto://user:pass@host/database` |
| `SECRET_KEY_BASE` | prod | — | Signs cookies and LiveView payloads (`mix phx.gen.secret`) |
| `ENCRYPTION_KEY` | prod | — | Encrypts CRCON API keys (`openssl rand -base64 32`) |
| `PHX_HOST` | prod | `example.com` | Public hostname |
| `PORT` | no | `4000` | HTTP port |
| `POOL_SIZE` | no | `10` | Database pool |
| `DEFAULT_LOCALE` | no | `en` | `en` or `pt_BR` |
| `ENGINE_ENABLED` | no | `true` | `false` serves the UI without connecting to CRCON |
| `EXECUTION_RETENTION_DAYS` | no | `30` | How long the rule history is kept |
| `CONNECT_DELAY_MS` | no | `5000` | How long to wait after a connect before evaluating rules |
| `DATABASE_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_NAME` | no | localhost/postgres | Development and test only |

**Losing `ENCRYPTION_KEY` means every stored CRCON API key has to be entered
again.** Keep it with your other secrets.

---

## Development

### With Docker (nothing to install)

```bash
docker compose up
```

Postgres, migrations, seeds and the server with code reloading, on
<http://localhost:4000>.

### Without Docker

Requires Elixir 1.17+, OTP 26+ and a PostgreSQL you can reach.

```bash
mix setup
mix phx.server
```

### Useful commands

```bash
mix test                  # the full suite
mix test --failed         # only what failed last time
mix precommit             # compile with warnings as errors, format, test
mix ecto.reset            # drop, create, migrate, seed
```

### Translations

The source language is English. After adding or changing a `gettext` call:

```bash
mix gettext.extract --merge
```

Then fill in the new entries in `priv/gettext/pt_BR/LC_MESSAGES/default.po`.

Visitors pick their language from **My account**; without a choice the app
follows the browser's `Accept-Language` header and falls back to
`DEFAULT_LOCALE`.

---

## Production

```bash
cp .env.example .env
# fill in PHX_HOST, SECRET_KEY_BASE, ENCRYPTION_KEY, POSTGRES_PASSWORD
docker compose -f compose.prod.yaml up -d --build
```

This builds a release image (`Dockerfile`), runs migrations before serving any
traffic, and publishes **only Caddy**. The app and Postgres are reachable on
the compose network and nowhere else, so nobody can go around the sign in form
by talking to port 4000.

### TLS

Caddy gets and renews the certificate itself. Point `PHX_HOST` at a hostname
that resolves to the machine, leave ports 80 and 443 free, and the first boot
fetches a Let's Encrypt certificate. `PHX_HOST=localhost` issues a local one
instead, which is what makes a laptop run work without ceremony.

The certificate lives in the `caddy_data` volume. Keep it: losing it means
asking Let's Encrypt for a new one, and that is rate limited.

### What is throttled

| Where | Limit | Catches |
| --- | --- | --- |
| Caddy, `POST /login` | 5/min per address | one machine hammering the form |
| Caddy, everything else | 300/10s per address | a flood |
| App, per address | 10/min | the same, if Caddy is not in front |
| App, per account | 20/hour | a botnet spreading guesses across addresses |

The account limit is the one that matters: it is the only one an attacker
cannot escape by renting more addresses. Both app limits are configurable —
raise the address one if your admins all sit behind a single office NAT:

```elixir
config :hll_conditional_actions, :login_rate_limit,
  ip: [limit: 30, window_ms: 60_000],
  username: [limit: 20, window_ms: 3_600_000]
```

The `rate_limit` directive needs a Caddy module that is not in the official
image, which is why `deploy/caddy/Dockerfile` builds one. To run stock Caddy,
comment that block out of the Caddyfile and point compose at `caddy:2-alpine`;
the app's own limits still apply.

### Health probes

| Path | Meaning |
| --- | --- |
| `GET /health` | The web process is up |
| `GET /health/ready` | The database answers too |

### Running migrations on their own

```bash
docker compose -f compose.prod.yaml run --rm app /app/bin/migrate
```

### Backups

Three things are worth keeping, and they are not the same kind of thing:

| What | Where | If you lose it |
| --- | --- | --- |
| The database | `db_data` volume | Rules, users and history are gone |
| `ENCRYPTION_KEY` | your `.env` | The database survives, but every CRCON key in it is unreadable and has to be entered again |
| `caddy_data` | volume | A new certificate is requested on next boot, which Let's Encrypt rate limits |

A database dump on a schedule:

```bash
docker compose -f compose.prod.yaml exec -T db   pg_dump -U "$POSTGRES_USER" hll_conditional_actions | gzip > backup-$(date +%F).sql.gz
```

Keep `.env` somewhere other than the same disk. A dump without its
`ENCRYPTION_KEY` restores everything except the ability to talk to any game
server.

### Two factor

Optional, per account, set up from **My account**. TOTP only — an
authenticator app, no email and no SMS, because this app sends neither.

- The secret is encrypted at rest, like a CRCON key, and nothing is stored
  until a code proves the app is reading it. Closing the page halfway changes
  nothing about how you sign in.
- Ten single-use recovery codes are shown once, and stored only as hashes.
- A code is accepted once. The time step it belongs to is remembered, so one
  read over a shoulder inside its 90 second window is already spent.
- Ten wrong codes in fifteen minutes and the account stops being answered.
- **The way back in** when the phone and the codes are both gone: anybody who
  can manage users has *Switch two factor off* in the row menu on **Users**.
  Keep a second administrator account for exactly this.

### Hardening notes

- The bootstrap account is `admin` / `admin` and must change its password on
  first sign in. The login page stops offering the hint the moment it does.
- CRCON API keys are encrypted at rest and marked `redact: true`, so they do
  not reach logs or `inspect` output.
- A key belonging to a CRCON superuser is refused: the connection test asks for
  the permissions it needs and nothing more.
- The session cookie is `http_only`, `secure` and `same_site=Lax`, and expires
  after a week.
- The app sets its own CSP, referrer and permissions policies, so they hold
  even if it is served without Caddy in front.

---

## Thanks

**[CRCON — Hell Let Loose Community RCON](https://github.com/MarechJ/hll_rcon_tool)**,
by [MarechJ](https://github.com/MarechJ) and its contributors.

This project stands entirely on it. CRCON does the hard part — holding the RCON
connection, parsing the game's logs into structured events, and putting a sane
API in front of both — and it is the reason this app can be a few thousand
lines of rule engine instead of a reimplementation of everything underneath.
The recipes that ship here are modelled on CRCON's own automods, and its
permission model is the one this app asks for and respects.

If you run a Hell Let Loose server, go and use CRCON. It is excellent.

- **GitHub:** <https://github.com/MarechJ/hll_rcon_tool>
- **Discord:** <https://discord.com/invite/zpSQQef>

Hell Let Loose is a trademark of Team17 / Expression Games. This is an
unofficial community tool, not affiliated with either.
