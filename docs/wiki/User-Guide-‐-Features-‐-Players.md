🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players)
***

# Players

## Menu

- [The list](#the-list)
- [A player's page](#a-players-page)
- [Acting on a player](#acting-on-a-player)
- [Permissions](#permissions)

***

Everyone your servers have seen, and one page per player that answers *"why
was I kicked?"*. **Players** is in the icon rail; it is not a module.

![Players](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/players.png)

## The list

`/players` joins what the app knows about a player into one row:

- CRCON's player history of your servers
- their match totals
- the rules that acted on them
- their tickets (if you may see tickets)

Only the servers you may see count. Who is online, VIP or on the watchlist is
read from CRCON after the page opens and refreshed every 30 seconds.

**Search** by name, Steam ID, clan or something they wrote in chat (press `/`
to jump to the box). From three characters on it also searches CRCON's
history.

| Filter | Shows |
| --- | --- |
| **Everyone** | The whole list |
| **Online now** | Playing on one of your servers |
| **VIP** | Holding VIP |
| **Watchlist** | On CRCON's watchlist |
| **With penalties** | With at least one penalty on their CRCON profile |
| **New this week** | First seen in the last 7 days |
| **+ Filter** | *Seen in matches*, *Hit by rules*, *With tickets* |

Sort by last seen (the default), playtime, penalties, rule hits or name. Each
row shows the level, playtime, sessions, penalties, rule hits, when they were
last seen and their marks — *VIP*, *Watchlist*, *Clan*, *Open ticket*, *Top
kills*, *New* and CRCON flags. Fifty rows at a time, **Load 50 more** for the
next. **Export CSV** downloads the list.

## A player's page

`/players/:player_id` — from the list, a ticket, the feed, the history or
**Ctrl K**.

![A player](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/player.png)

On top: the name, level, where they are playing now, *Watchlist*,
*Blacklisted* or *VIP until…*, then playtime, K/D over the last 10 matches,
team kills in the last 30 days, penalties and achievements.

| Tab | What is in it |
| --- | --- |
| **Overview** | A timeline of penalties, rule runs and tickets; the last 10 matches; the rules that hit them most, with *Why did a rule not fire for them?* |
| **Rules that hit them** | Every run: when, which rule, server, outcome, what it did |
| **Matches** | Map, server, team, kills, deaths, team kills, time |
| **Tickets** | Their tickets (with `view_tickets`) |
| **VIP purchases** | What they bought in the [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop) |

It is read from the history, so a player who left an hour ago is still
answerable.

## Acting on a player

With **Act on players** (`manage_players`), the page has:

| Button | Notes |
| --- | --- |
| **Message** | A private message in game |
| **Punish**, **Kick** | Only while the player is on a server |
| **Ban for a while…** | 1, 2, 6 or 24 hours (up to a year) |
| **Ban for good…** | Permanent |
| **Add to / Remove from the watchlist** | With why you are watching them |
| **Give VIP…** / **Remove VIP** | 7, 30 or 90 days, or no end |

Every action opens a confirmation with the server (when you have more than
one) and a reason of up to 200 characters — the text the player reads, or the
note CRCON keeps. Punish, kick and ban reasons are signed with your name. A
ban also asks you to **type the player's name** to confirm.

The same actions — message, punish, kick and a two-hour ban — are on each
[ticket](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets),
for the player who called and for the one they reported, and **Ban** and
**Message** are offered in **Ctrl K** next to the player found.

## Permissions

| Permission | Grants |
| --- | --- |
| `view_stats` | *See matches, players and leaderboards*: the list and the player page |
| `manage_players` | *Act on players*: every button above, on the servers the account reaches |
| `view_tickets` | The player's tickets |

`manage_players` is new in v0.3.0 and is not implied by any other permission.
The upgrade gave it to every role that could manage tickets, so nobody lost
the buttons they had.

---

***

**←** [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Live cockpit and feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) **→**
