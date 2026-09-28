🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Live feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed)
***

# Live feed

## Menu

- [Turning it on](#turning-it-on)
- [Using the feed](#using-the-feed)
- [Where the events come from](#where-the-events-come-from)
- [Permissions](#permissions)
- [Tips](#tips)

***

Kills, chat and connections as they happen on your servers — the exact events
the rule engine sees.

## Turning it on

1. Install **Live feed** from the server's
   [marketplace](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features).
2. Make sure the server has **Consume the live log stream** on (see
   [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server)).

Open **Live feed** under the server (`/servers/:id/feed`), or `/feed` for every
server you may see.

## Using the feed

- New events appear at the top, with the time, the server, the event and
  its details.
- Filter by **server** and by **event type**.
- **Pause** stops the list moving while you read — events arriving while
  paused are dropped, not queued. **Resume** picks up from there.
- **Clear** empties the list.
- The page keeps the last **300** events, so a busy fleet cannot slow the
  browser down.

Nothing is stored: the feed shows what arrives while the page is open.

## Where the events come from

Each server keeps one WebSocket to CRCON's `/ws/logs` endpoint, authenticated
with the server's API key. This needs the CRCON permission
`can_view_structured_logs` and the log stream enabled in CRCON's own config.

A dropped connection reconnects on its own, backing off from one second up to
thirty, and resumes from the last event it saw instead of replaying the whole
buffer. A stream in error shows up in
[Attention](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history).

## Permissions

| Permission | Grants |
| --- | --- |
| `view_live_feed` | *Watch the live event feed* |

## Tips

- Writing a rule for a trigger? Open the feed, do the thing in game, and check
  the event arrives before wiring an action to it.
- An empty feed on a busy server usually means the stream is down — check the
  server page or Attention.

---

***

**←** [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) **→**
