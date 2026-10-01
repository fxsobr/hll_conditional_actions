🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Inbox and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history)
***

# Inbox and history

## Menu

- [The Inbox](#the-inbox)
- [What lands in it](#what-lands-in-it)
- [Working an item](#working-an-item)
- [History](#history)
- [Metrics and the Briefing](#metrics-and-the-briefing)
- [In the background](#in-the-background)
- [Permissions](#permissions)

***

Where to look when you want to know what needs you and what the rules did.
Both are always there — no module to install.

## The Inbox

![The Inbox](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/attention.png)

**Inbox** in the icon rail (`/inbox`) is one list of everything that needs an
admin: **attention items** worked out from what the app already knows, and
the players' **tickets** (see
[Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets)).
The rail's badge counts what is open.

The most urgent come first — errors and urgent tickets, then warnings and
high-priority tickets, then the rest — and the list updates live (and every
30 seconds regardless).

| Control | What it does |
| --- | --- |
| **Everything / Mine / Unowned** | Owner tabs, with counts |
| **Urgent** | Errors and urgent or overdue tickets |
| **Tickets** | Tickets only |
| **Rules** | Streams down, broken or failing rules |
| **Players** | Players to review, VIP purchases not delivered |
| **Suggestions** | Rules ready to go live, rules gone quiet |
| **Solved** | Closed tickets, and how many items were marked as handled |
| **Search by player or ticket** | |

Click a chip again to turn it off. **Turn on alerts** in the header makes
this browser play a sound and show a desktop notification when a ticket
arrives, on any page of the app — turn it on on the machine where the panel
stays open. **Configure tickets** leads to the ticket settings.

## What lands in it

Items appear and disappear by themselves as the situation changes:

| Item | Shows when | Handled? |
| --- | --- | --- |
| **Stream down** | An enabled server is not streaming events — no rule can react to it until it is back | Goes away when the stream is back |
| **Ticket waiting** | A ticket waited longer than the server's *alert after minutes* — shown as the ticket itself, turned urgent | Answer it |
| **Rule broken** | A rule can never work, or fails every time | Fix the rule |
| **Failures** | A rule's actions failed in the last 24 hours | Yes — back on the next failure |
| **Review** | A rule put a player on the watchlist or flagged them in the last 7 days, for a human to look at | Yes |
| **Ready to go live** | A rule has simulated for 3 days, with some runs and no failure — the same measure as *Ready to act* on its page | Yes |
| **Rule quiet** | A rule that never fires, or stopped firing | Yes |
| **Paid VIP not granted** | A [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop) order that could not be delivered on some server | Yes |

The same items feed the
[notifications bell](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface#notifications)
and the Briefing's *Needs you*.

## Working an item

Click an item and it opens beside the list: its severity (*Urgent*, *To
review*, *Suggestion*), the facts behind it and the one link that deals with
it — the rule, the server, the player, the order.

**Mark as handled** takes it off **everybody's** inbox. It comes back if it
happens again: a rule that fails after being handled returns.

For a player to review, the Inbox also tells you when a watched player is
back on a server (*(player) is back*).

## History

![History](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/history.png)

**Rules → History** (`/executions`, or `/servers/:id/history` for one server)
records every time a rule fired: when, for whom, on which server, and what
each action did. It comes with the **Conditional rules** module.

- Filter by rule, server, result, player name or ID, and the period (24
  hours, 7 or 30 days, everything kept, or dates). **Export CSV** downloads
  what is filtered.
- On top: runs in 30 days, the success rate, players reached, and the runs
  by result.
- Click a run for its **trace** — *why it fired*: each condition with the
  value read against the value needed, cooldown and daily limit, the
  escalation step (*Offence 2 of 3*), exemptions, each action's outcome
  (Discord posts show *Delivered* or *Not delivered*) and how long it took.
  From there: **Open in the builder**, **Open in the simulator**, the player's
  profile.
- Simulated runs are marked *Simulated* — recorded without touching the game.
- Page 1 updates live and tags new rows *NEW*; later pages hold still while
  you read.

Each rule's page has the same list, for that rule, under **Executions**.

## Metrics and the Briefing

- **Engine metrics** (`/metrics`) — events, rule fires and skips, CRCON call
  timings. Now under **Settings**: see
  [Settings and account](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account#engine-metrics).
- **The Briefing** (`/`) — rule fires over 7, 30 or 90 days, what needs you
  and every server now: see
  [The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface#briefing-the-home-page).
- **A player's page** (`/players/:player_id`) — every rule that hit them: see
  [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players).

## In the background

| Job | When | What |
| --- | --- | --- |
| `PruneExecutions` | daily at 04:00 | Deletes history older than `EXECUTION_RETENTION_DAYS` (default 30) |

## Permissions

| Permission | Grants |
| --- | --- |
| `view_executions` | *View the rule history*: History, the Inbox, engine metrics and the Briefing's numbers |
| `view_rules` | The rule items in the Inbox (broken, failing, quiet, ready to go live) |
| `view_tickets` | Tickets in the Inbox |
| `manage_integrations` | *Paid VIP not granted* items |
| `manage_rules` | **Mark as handled** |

---

***

**←** [Mercado Pago](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Mercado-Pago) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules) **→**
