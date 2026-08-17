🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Developer Guides](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides) / [Architecture](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Architecture)
***

# Architecture

## Menu

- [The supervision tree](#the-supervision-tree)
- [Where the work happens](#where-the-work-happens)
- [Stack](#stack)
- [Artwork](#artwork)
- [Observability](#observability)

***

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

## The supervision tree

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

## Where the work happens

- **Evaluation is cheap.** Every rule for one event shares a single CRCON
  snapshot (`get_detailed_players` + `get_gamestate`), cached for a few seconds.
  A busy firefight does not turn into an API flood.
- **In-game consequences run inline.** A kick that lands thirty seconds late
  punishes a situation that has already passed, so punishments are not queued.
- **Everything retryable goes through Oban.** Discord webhooks, restoring a
  temporary broadcast, pruning old history.
- **The audit row is written first.** It is what the cooldown check reads, so
  two events arriving back to back cannot both slip past the limit.

## Stack

Phoenix 1.8 · LiveView 1.2 · Tailwind CSS 4 + Petal Components · Alpine.js ·
Ecto/PostgreSQL · Oban · Caddy · TOTP two factor ·
Gettext (English + Brazilian Portuguese)

## Artwork

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

## Observability

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

***

**↑** [Developer Guides](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides) · [Development environment](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment) **→**
