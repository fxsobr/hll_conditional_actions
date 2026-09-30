🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets)
***

# Tickets

## Menu

- [Turning it on](#turning-it-on)
- [What players type](#what-players-type)
- [The inbox](#the-inbox)
- [Answering a ticket](#answering-a-ticket)
- [Settings](#settings)
- [Tickets opened by rules](#tickets-opened-by-rules)
- [Metrics](#metrics)
- [In the background](#in-the-background)
- [Permissions](#permissions)
- [Tips](#tips)

***

Players call an admin from the in-game chat; admins answer from the web, and
the answer reaches the player as a private message in game.

![Tickets](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/tickets.png)

## Turning it on

1. Install **Tickets** from the server's
   [marketplace](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features).
2. Open **Tickets → Start the wizard** (`/servers/:id/tickets/setup`, or
   `/tickets/setup` to set up several servers at once).

The wizard asks only what matters, one step at a time, with an in-game preview
of every message:

| Step | What you choose |
| --- | --- |
| Servers | Which servers take tickets (only from `/tickets/setup`) |
| Commands | What players type, e.g. `!admin` |
| Categories | Optional |
| Messages | What the player reads |
| Office hours | Optional |
| Review | A summary, then **Save and turn on** |

Nothing is saved before the last step. Everything else keeps a sensible
default and lives in the settings page.

> [!IMPORTANT]
> Tickets read the game chat from the live log stream. A server with
> **Consume the live log stream** turned off never opens a ticket from chat.

## What players type

With the command `!admin` (up to ten commands per server, one word each, case
ignored):

| Chat line | What happens |
| --- | --- |
| `!admin tk on the bridge` | Opens a ticket with that text |
| `!admin` | Opens a ticket too |
| `!admin cheat aimbot on the hill` | Opens a ticket in the category `cheat`, when the server lists it |
| anything else, while a ticket is open | Added to the open ticket, so the conversation reads as one thread |
| `!admin status` | Tells the player where their ticket stands (the word is a setting) |
| `!admin close` | The player closes their own ticket (the word is a setting) |

The command must be the **first word**: *"don't type !admin"* opens nothing.
A player has at most one open ticket per server.

## The inbox

**Tickets** lists every ticket on the servers you may see, or one server's
under `/servers/:id/tickets`. Higher priorities come first, then the most
recent activity, and the list updates live.

- **Views** with counts: *Unassigned*, *Mine*, *Waiting for an admin*,
  *Waiting for the player*, *All open*, *Closed*.
- Filter by server, category, or player name / ID.
- The row's colour ages with the wait (*Just arrived*, *Waiting for a while*,
  *Waiting too long*), and **Claim** assigns it to you from the row.

## Answering a ticket

The ticket page shows:

- **Conversation** — player lines, admin answers, automatic messages, and
  whether each answer was delivered. A reply CRCON refused is still saved,
  marked *Not delivered* (the player may have left).
- **Before the call** — the chat and the player's kills, deaths and team
  kills in the five minutes before the ticket opened.
- **The player card** — online or not, level, VIP, clan, playtime, past
  penalties, earlier tickets.
- **Quick replies** — one click fills the answer box.
- **Internal note** — kept with the ticket for the other admins, never sent
  to the player.
- **Assign** — to yourself or another admin who may answer tickets on that
  server; they are told it was handed to them.
- **Priority** — low, normal, high, urgent.
- **Act on a player** — *Punish*, *Kick*, *Add to the watchlist* or
  *Temporary ban* (1 hour to 1 year), with a reason. It runs on the ticket's
  player or on another player ID (the one being reported), and is recorded
  in the conversation.
- **Close ticket** / **Reopen** — the player is told it was closed.

Answers are sent as `[ADMIN {admin}] text` by default; the prefix is a
setting, and `{admin}` becomes your name.

## Settings

**Tickets → Ticket settings** (`/servers/:id/tickets/settings`). The form has
seven sections, saved together:

![Ticket settings](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/ticket-settings.png)

| Section | Settings |
| --- | --- |
| **Commands** | On/off, the commands, the *status* and *close* words |
| **Categories** | Up to 20 one-word categories, each with a priority; the priority of a ticket without one |
| **Messages** | When the ticket is opened, before each answer (`{admin}`), when it is closed. `{player}` and `{command}` work in the notices. A blank message is not sent |
| **Quick replies** | Up to 20, shown as buttons on each ticket |
| **Office hours** | Days and a time window in the server's time zone (a window past midnight is fine); what the player reads outside it |
| **Limits and alerts** | Seconds between tickets (default 60), tickets per player per hour (0 = no limit), close after hours without activity (default 12, 0 = never), alert after minutes without an answer (default 5, 0 = off) |
| **Discord** | Announce new tickets on a registered webhook, and which role ids to mention |

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

**Tickets → Metrics**, for 24 hours, 7 or 30 days: tickets opened and open
now, average and median first answer, answers by admin, tickets by server and
by hour of the day (in the server's time zone), and the players who call the
most.

## In the background

| Job | When | What |
| --- | --- | --- |
| `CloseStaleTickets` | every 10 minutes | Closes tickets silent for longer than the server's *close after hours* and tells the player |
| Ticket listener | while the server streams | Reads the chat, opens and fills tickets |
| Discord announcement | on each new ticket | Queued like any Discord message, so a slow Discord never delays the ticket |

A ticket waiting longer than *alert after minutes* shows as urgent in
[Attention](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history).

## Permissions

| Permission | Grants |
| --- | --- |
| `view_tickets` | *See player tickets*: the inbox, a ticket, the metrics |
| `manage_tickets` | *Answer and close player tickets*, plus the settings and the wizard |
| `manage_players` | *Act on players*: message, punish, kick, ban and watch the caller or the reported player from a ticket (and the same, plus VIP, from the player pages) |

Users only see tickets of the servers assigned to them.

## Tips

- Keep categories short and meaningful (`cheat`, `tk`, `bug`): the player types
  them right after the command.
- Leave the *seconds between tickets* on — it stops a player from opening
  ticket after ticket.
- Use office hours so players are not promised an answer at 4 a.m.

---

***

**↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) **→**
