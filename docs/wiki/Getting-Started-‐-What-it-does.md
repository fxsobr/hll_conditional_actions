🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [What it does](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-What-it-does)
***

# What it does

## Menu

- [Beyond rules: the modules](#beyond-rules-the-modules)
- [How it connects to CRCON](#how-it-connects-to-crcon)
- [Requirements on the CRCON side](#requirements-on-the-crcon-side)

***

This app watches the events CRCON reports and answers them the way an
admin would: a warning, a team switch, a kick, a note in Discord. A rule
is *when something happens, if it matches, do this* — chosen from
dropdowns, never scripted.

Both games are supported and kept separate throughout: **HLL** (WW2) and
**HLLV** (Hell Let Loose: Vietnam) have different roles, teams, maps and
game modes, so a rule always declares which game it is written for.

**The Briefing** — what needs you, the rule ready to leave simulation, how
often the rules fired, and every server's live score and population.

![Briefing](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/briefing.png)

**Live** — the match over the map, and the feed with the rules each line
fired.

![The cockpit](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/cockpit.png)

**The rule builder** — the rule as a sentence, conditions in groups, and a
test bench: the last runs overlaid on your edit, and the draft replayed over
the last week of real events before you publish it.

![The rule builder](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule-builder.png)

**A rule's own page** — whether it is ready to act for real, the escalation
ladder with its counts, every run with its trace, why it did not fire for a
player, and every version.

![A rule](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule.png)

How to find your way around:
[The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface).

## Beyond rules: the modules

Rules are one module among several. Each server installs the ones it wants
from its **Modules** page; a new server starts with none, and removing a
module hides its pages and stops its work without deleting its data.

![Modules](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/marketplace.png)

| Module | |
| --- | --- |
| **Conditional rules** | Everything above, plus the history, the simulator and the "why didn't it fire?" diagnosis. |
| **[Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets)** | Players type a command in the game chat to call an admin; the conversation continues from the Inbox. |
| **[Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches)** | The current match's best players and squads, and every past scoreboard. |
| **[Live feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed)** | The game's events as they happen, with the rules they fired. |
| **[Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons)** | Goals unlocked by playing, and seasons that reward the best. |
| **[VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop)** | A public storefront where players buy VIP, paid with Stripe, Dodo Payments or Mercado Pago. |

Always there, with no module: the Briefing, the cockpit, the
[Inbox](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history),
[Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players),
[Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord)
and [Settings](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account).

**The Inbox** — attention items and tickets in one list, with the
conversation, the reported player and what you can do about them.

![Tickets](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/tickets.png)

**A finished match** — the result, the MVP and the best players of every
category.

![A match](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/match.png)

The whole list: [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features).

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

## Requirements on the CRCON side

1. A CRCON user with an **API key** (Django admin → *Django API Keys*).
2. That user needs the `can_view_structured_logs` permission, plus whatever the
   actions your rules use require (`can_message_players`, `can_punish_players`,
   `can_kick_players`, `can_temp_ban_players`, ...).
3. **The log stream turned on**, in CRCON under
   *Settings → Others → Log Stream*, with `enabled` set to `true`. It ships
   disabled, and without it CRCON accepts the WebSocket connection and then
   immediately refuses to send anything — the connection test says the log
   stream did not answer, and once saved the server shows as *stream down* in
   its cockpit and in the Inbox.

Creating a dedicated user for this app is recommended: CRCON records the API
key's owner as the author of every action, so its work shows up clearly in the
CRCON audit log.

---

***

**↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) · [Requirements](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements) **→**
