🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Attention and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history)
***

# Attention and history

## Menu

- [Attention](#attention)
- [History](#history)
- [The player page](#the-player-page)
- [Metrics](#metrics)
- [The overview](#the-overview)
- [In the background](#in-the-background)
- [Permissions](#permissions)

***

Where to look when you want to know what needs you, what the rules did, and
whether the engine is healthy.

## Attention

![Attention](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/attention.png)

**Attention** (`/attention`, or `/servers/:id/attention`) is one inbox of what
needs an admin now, most urgent first, each with the one link that deals with
it. It is always available — no module to install — and refreshes on its own
every 30 seconds.

Items are worked out from what already exists, so they appear and disappear by
themselves:

| Item | Shows when |
| --- | --- |
| **Stream down** | An enabled server is not streaming events — no rule can react to it until it is back |
| **Ticket waiting** | A ticket waited longer than the server's *alert after minutes* |
| **Rule broken** | A rule can never work, or fails every time |
| **Failures** | A rule's actions failed in the last 24 hours |
| **Review** | A rule put a player on the watchlist or flagged them in the last 7 days, for a human to look at |
| **Ready to go live** | A rule has been in simulation for 3 days and at least 10 runs without a failure |
| **Rule quiet** | A rule that never fires, or stopped firing |

Filter by *Urgent*, *To review* and *Suggestions*. **Handled** makes an
item leave for everybody — until it happens again: a rule that fails after
being handled comes back.

## History

![History](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/history.png)

**History** (`/executions`, or `/servers/:id/history`) records every time a rule
fired: when, for whom, on which server, and what each action did. It comes with
the **Conditional rules** module.

- Filter by rule, server, outcome, player name or ID, and a date range.
- **Details** shows the trigger received, each condition with the value read
  against the value needed, each action's outcome (Discord posts show
  *Delivered*, *Queued* or *Not delivered*), the escalation step
  (*Offence 2 of 3*) and how long it took.
- Simulated runs are marked *Simulated* — recorded without touching the game.
- The first page updates live; later pages hold still while you read.
- At the top: how often rules fired in 30 days, the success rate and how many
  different players were reached.

## The player page

`/players/:player_id` answers *"why was I kicked?"* in one place: which rules
hit the player, how many times, the punishments, their achievements, and the
run-by-run detail. It is read from the history, so a player who left an hour
ago is still answerable. Needs `view_stats`.

## Metrics

![Metrics](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/metrics.png)

**Metrics** (`/metrics`) shows what the engine is doing, refreshed every two
seconds:

- game events received and log stream connections — repeated reconnects mean
  a server the app cannot hold a stream to
- rules fired, and **why rules were skipped** (conditions did not hold,
  cooldown, per-player cap, player exempt)
- CRCON calls by outcome, and round trip by endpoint (average, slowest, last)
- time from decision to actions finishing

Counters start at zero when the application starts; **Reset** clears them.

## The overview

The home page (`/`) sums up what the rules did over **7, 30 or 90 days**,
compared with the period before: executions fired, failed and simulated per
day, by trigger, and the busiest rules with their success rate and reach. It
only counts servers you may see.

## In the background

| Job | When | What |
| --- | --- | --- |
| `PruneExecutions` | daily at 04:00 | Deletes history older than `EXECUTION_RETENTION_DAYS` (default 30) |

## Permissions

| Permission | Grants |
| --- | --- |
| `view_executions` | *View the rule history*: History, Attention, Metrics and the overview numbers |
| `manage_rules` | Marking an attention item as handled |
| `view_stats` | The player page |

---

***

**←** [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules) **→**
