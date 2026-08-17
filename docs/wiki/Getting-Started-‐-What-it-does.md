🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [What it does](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-What-it-does)
***

# What it does

## Menu

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

**Overview** — the servers, whether their log streams are live, and what the
rules have been doing.

![Overview](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/overview.png)

**The rule builder** — setup, trigger, conditions, actions and limits as steps,
with the rule reading back in plain words beside them.

![The rule builder](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule-builder.png)

**A rule's own page** — how often it fired, how many players it reached, what
failed, and every change ever made to it.

![A rule](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule.png)

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
   immediately refuses to send anything — the server shows up as *Error* on the
   dashboard with that explanation.

Creating a dedicated user for this app is recommended: CRCON records the API
key's owner as the author of every action, so its work shows up clearly in the
CRCON audit log.

---

***

**↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) · [Requirements](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements) **→**
