🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets)
***

# Tickets

## Menu

- [Turning it on](#turning-it-on)
- [What players type](#what-players-type)
- [Tickets in the Inbox](#tickets-in-the-inbox)
- [Answering a ticket](#answering-a-ticket)
- [Settings](#settings)
- [Tickets opened by rules](#tickets-opened-by-rules)
- [Metrics](#metrics)
- [In the background](#in-the-background)
- [Permissions](#permissions)
- [Tips](#tips)

***

Players call an admin from the in-game chat; admins answer from the
[Inbox](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history),
and the answer reaches the player as a private message in game.

![A ticket in the Inbox](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/tickets.png)

## Turning it on

1. Install **Tickets** from the server's
   [Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
   page.
2. **Inbox → Configure tickets** opens the setup **Assistant**
   (`/tickets/setup`, or `/servers/:id/tickets/setup` for one server). Once
   tickets are on somewhere, the same button opens the settings, and the
   Assistant stays one of the Inbox's tabs.

The assistant asks only what matters, one step at a time, with a preview of
how the player sees it in game — the first call, a second call, a call
without a reason:

| Step | What you choose |
| --- | --- |
| Servers | Which servers take tickets (only from `/tickets/setup`) |
| Commands | What players type (e.g. `!admin`), whether case matters, whether to ask for the reason, the wait between calls, **how many tickets a player may have open at once** (1 to 5), who may call (every player, players with some playtime, VIPs only) and who never may (CRCON flags, players banned in the last 24 hours) |
| Categories | Optional |
| Messages | What the player reads |
| Office hours | Optional |
| Review | A summary, then **Save and turn on** |

While tickets are off, each step is kept as a draft: **Save and exit** and come
back later. Everything else keeps a sensible default and lives in the
settings page.

> [!IMPORTANT]
> Tickets read the game chat from the live log stream. A server with
> **Consume the live log stream** turned off never opens a ticket from chat.

## What players type

With the command `!admin` (up to ten commands per server, one word each):

| Chat line | What happens |
| --- | --- |
| `!admin tk on the bridge` | Opens a ticket with that text |
| `!admin` | Opens a ticket too, and asks for the reason if the server is set to |
| `!admin cheat aimbot on the hill`, or `!admin 4 aimbot…` | Opens a ticket in the category `cheat` — by its name or its number in the list |
| `2`, while the ticket has no category | Picks the second category |
| anything else, while a ticket is open | Added to the newest open ticket, so the conversation reads as one thread |
| `!admin status` | Tells the player where their ticket stands (the word is a setting) |
| `!admin close` | The player closes their own ticket (the word is a setting) |

The command must be the **first word**: *"don't type !admin"* opens nothing.

A player may have as many tickets open as the server allows (**one** by
default, up to five). At the limit, a new call joins the newest ticket and the
player is told which one is open. Too soon after the last call, the player
reads *Wait a few minutes before calling an admin again*; past the hourly
limit, nothing happens.

## Tickets in the Inbox

Open tickets share the **Inbox** with the attention items, most urgent first:
urgent or overdue tickets on top, then high priority, then the rest, then
answered ones. The list updates live.

- **Everything / Mine / Unowned** — the owner tabs, with counts
- **Tickets** — the chip that shows tickets only; **Solved** shows closed ones
- **Search by player or ticket**
- each row shows its category colour, how long the player has waited against
  the server's alert time, and who has it: *unassigned*, *With you*, *With
  (admin)*, *Waiting for the player*

`/tickets` still lists tickets on their own, with the views *Unassigned*,
*Mine*, *Waiting for an admin*, *Waiting for the player*, *All open* and
*Closed*.

## Answering a ticket

Click a ticket and the conversation opens beside the list (or on its own page,
`/tickets/:id`):

- **The conversation** — player lines, answers, automatic messages, internal
  notes, and whether each answer was delivered. A reply CRCON refused is still
  saved, marked *Not delivered* (the player may have left).
- **Answer in game** or **Internal note** — a note is kept for the other
  admins and never sent. Mention an admin as `@username` and they get a
  [notification](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface#notifications).
- **Quick replies** above the answer box — one click fills it; some also
  close the ticket when sent.
- **Assign to me** / **Release**, **Reopen**, **Close** with a reason
  (*Resolved*, *Duplicate*, *No action needed*, *Player left*, *Other*). The
  player is told it was closed.
- **More options** — the priority (low, normal, high, urgent), **Hand the
  ticket to** another admin who may answer on that server, **Who is it
  about** (the reported player), the transcript, earlier tickets.
- On a wide screen, cards beside the conversation: **Who called** (online or
  not, how many calls, penalties, VIP, watchlist), **Before the call** (chat
  and kills in the minutes before), and **Reported**.

**Acting on a player** — **Message**, **Punish**, **Kick** or **Ban 2 h**, on
the player who called or the one they reported. You type the text the player
reads; the action is recorded in the ticket and in the player's history. This
needs **Act on players** (`manage_players`). More actions are on the
[player's page](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players).

Answers go out with the *Answered* prefix from the settings, where
`{admin_name}` becomes your name.

## Settings

**Inbox → Configure tickets → Settings** (`/tickets/settings`, or
`/servers/:id/tickets/settings`). A **Tickets on/off** switch on top, and
**Save changes** / **Discard** with the count of unsaved changes.

![Ticket settings](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/ticket-settings.png)

| Section | Settings |
| --- | --- |
| **Categories** | Up to 20, each with a priority and a **colour** (red, amber, lime, teal, lavender, grey), in the order players see them. Each shows how many tickets it had this month |
| **Close on its own** | Close after *N* hours without activity (1 to 168, 12 by default), and **Warn the player 1 h before closing** |
| **Discord alert** | The webhook to announce new tickets on, which role ids to mention, and from which priority (any, normal or above, high or urgent, urgent only) |
| **Quick replies** | Up to 20, each with a title, the text, and **Closes the ticket when sent**. Each shows how many times it was used (*used N×*) |
| **Messages in game** | *Opened*, *Answered* (the prefix) and *Closed*. `{player_name}`, `{ticket_id}`, `{category}`, `{categories}`, `{admin_name}` and `{server_name}` work in them |
| **Office hours** | Per weekday, **several time ranges** (**+ Time range**; a range may run past midnight, `24:00` closes at midnight), in the server's time zone. What the player reads outside them, whether tickets are still taken, and whether urgent ones still alert on Discord |
| **More settings** | The commands, *alert after minutes without an answer* (5 by default, 0 = off), *tickets per player per hour* (0 = no limit), the priority of a ticket without a category, the *status* and *close* words |

The wait between calls, the open tickets per player and who may call are set
in the assistant.

Under `/tickets/settings` you tick one or more servers and the same settings
are saved to each — ticking a single server loads what it has, so it also
works as *copy this server's settings to others*.

## Tickets opened by rules

The rule action **Open a ticket for the admins** opens a ticket on behalf of
a rule — three team kills in five minutes, a slur in chat — with a note and a
priority. It works whether or not tickets are on for the server, the player
is not told, and it does not count against the player's limits. If the player
already has a ticket open, the note joins it and a higher priority raises it.

## Metrics

![Ticket metrics](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/ticket-metrics.png)

**Inbox → Metrics** (`/tickets/metrics`), over 7, 30 or 90 days, each number
compared with the period before, for one server or all:

- **Tickets per day**, and which weekday takes the most
- **First answer** within office hours — median, p90, and how many were
  answered within 1, 3, 5 and 15 minutes
- **Calls per hour** — a weekday × hour map, to plan office hours
- **Who answered** — the median per admin, answers outside office hours, and
  tickets closed without an answer
- **By category**, and **who calls the most** — and who is reported the most

**Export CSV** downloads the numbers.

## In the background

| Job | When | What |
| --- | --- | --- |
| `CloseStaleTickets` | every 10 minutes | Warns the player an hour before (when set), then closes tickets silent for longer than *close after hours* |
| Ticket listener | while the server streams | Reads the chat, opens and fills tickets |
| Discord announcement | on each new ticket | Queued like any Discord message, so a slow Discord never delays the ticket. Outside office hours only urgent tickets are announced, when set |

A ticket waiting longer than *alert after minutes* turns urgent in the Inbox.

## Permissions

| Permission | Grants |
| --- | --- |
| `view_tickets` | *See player tickets*: tickets in the Inbox, a ticket, the metrics |
| `manage_tickets` | *Answer and close player tickets*: answering, notes, assigning, priority, closing, the settings, the assistant and **Configure tickets** |
| `manage_players` | *Act on players*: message, punish, kick and ban the caller or the reported player |

The Inbox itself needs `view_executions`. Users only see tickets of the
servers assigned to them.

## Tips

- Keep categories short and meaningful (`cheat`, `tk`, `bug`): the player types
  them right after the command, or answers with their number.
- Keep a *wait between calls* — it stops a player from opening
  ticket after ticket.
- Use office hours so players are not promised an answer at 4 a.m.

---

***

**↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) **→**
