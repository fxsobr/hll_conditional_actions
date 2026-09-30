🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Live cockpit and feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed)
***

# Live: the cockpit and the feed

## Menu

- [Turning it on](#turning-it-on)
- [The cockpit](#the-cockpit)
- [The feed](#the-feed)
- [What the rules did, line by line](#what-the-rules-did-line-by-line)
- [Where the events come from](#where-the-events-come-from)
- [Permissions](#permissions)
- [Tips](#tips)

***

**Live** in the icon rail answers *what is happening on the server right
now*: the match over the map, the events as they arrive, and what the rules
did about each one.

![The cockpit](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/cockpit.png)

## Turning it on

The cockpit (`/servers/:id`) is always there — it needs no module. What it can
show grows with what the server has:

1. Install **Live feed** from the server's
   [Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
   page to see every log line (kills, chat, connections). Without it the
   cockpit shows only the rules' own activity, titled *Latest activity*.
2. Make sure the server has **Consume the live log stream** on (see
   [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server)).
3. Install **Leaderboard and matches** for the *Scoreboard* and *Squads*
   views (see
   [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches)).

**Live** opens the cockpit of the server in scope, or of your first server.
Pick another one in the scope switcher in the header.

## The cockpit

The page refreshes every 15 seconds. The map, score and players are read from
CRCON in the background, so a slow server shows placeholders instead of a
frozen page.

**The match, over the map:**

- *Live match* — lit only while the log stream is connected
- the map, the mode and when it started (server time zone)
- the score in team colours, the five sectors and the time left
- *Players* with the Allies/Axis balance, *In queue* and *VIPs playing*
- the log stream's state: connected, connecting, down or off

If CRCON does not answer, the title says *CRCON is not answering*.

**Beside the feed:**

| Panel | What it shows |
| --- | --- |
| **Best of the match** | The leader in kills, support and defense, with a link to the scoreboard |
| **Rules in this match** | How many times rules acted since the match started, and the six busiest, each marked *failing* or *simulating* when it is (wide screens) |
| **Needs you** | Up to three items from the Inbox, such as a stream down or a waiting ticket with **Take it** (phones) |

**Message everyone** sends a message every player on the server sees on their
screen (up to 300 characters). It needs `manage_servers`.

The feed panel has a switch between **Feed**, **Scoreboard** and **Squads**,
so you can glance at the rankings without leaving the page.

## The feed

The cockpit shows the server's feed; **`/feed`** shows every server you may
see, each line with its server's name.

![The feed](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/feed.png)

Each line reads as a sentence: *X killed Y · weapon*, *killed a teammate*,
chat *to everyone / in the team / in the squad*, *joined the server · level N*,
*left the server · played 34 min*, *switched teams*.

| Control | What it does |
| --- | --- |
| **All / Kills / Chat** | What kind of line to show |
| **Only where rules acted** | Hide every line no rule answered |
| **Pause the feed** | Stop the list moving while you read. New lines wait and appear when you **resume** |
| **Every server** (`/feed` only) | Narrow to one server |
| **Clear** (`/feed` only) | Empty the list |

The page opens with the latest lines already there (60 per server on `/feed`)
and keeps the newest **300**. Nothing is stored for the feed itself: it shows
what CRCON sends while the page is open.

## What the rules did, line by line

A line that a rule answered carries the rule as a pill, linked to the rule's
page:

- the rule's name, or *rule · step N* for an escalation ladder
- *· simulated* (lavender), *· failed* (red) or *· partly failed* (amber) —
  and the whole line is tinted to match
- at most two pills per line, then *+N*

A chat line that opened a ticket carries **Ticket #N**, linked to the ticket.
Rules that act with no log line behind them (scheduled rules, for example)
show as their own line with a bolt: *Message sent to X*, *Kicked X*,
*Ticket opened for X*.

So *why was that player kicked?* is answered in the feed itself: the kill,
and right on it, the rule that acted.

## Where the events come from

Each server keeps one WebSocket to CRCON's `/ws/logs` endpoint, authenticated
with the server's API key. This needs the CRCON permission
`can_view_structured_logs` and the log stream enabled in CRCON's own config.

A dropped connection reconnects on its own, backing off from one second up to
thirty, and resumes from the last event it saw instead of replaying the whole
buffer. A stream in error shows up in the cockpit and in the
[Inbox](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history).

## Permissions

| Permission | Grants |
| --- | --- |
| `view_servers` | The cockpit |
| `view_live_feed` | *Watch the live event feed*: the log lines and `/feed` |
| `view_stats` | *Best of the match*, the *Scoreboard* and *Squads* views |
| `manage_servers` | **Message everyone** |
| `manage_tickets` | **Take it** on a waiting ticket |

## Tips

- Writing a rule for a trigger? Open the feed, do the thing in game, and check
  the event arrives before wiring an action to it.
- **Only where rules acted** is the quickest way to watch a new rule in
  simulation: every line it would have acted on is tinted lavender.
- An empty feed on a busy server usually means the stream is down — the
  cockpit says so under the score.

---

***

**←** [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) **→**
