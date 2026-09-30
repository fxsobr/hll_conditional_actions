🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches)
***

# Leaderboard and matches

## Menu

- [Turning it on](#turning-it-on)
- [The live leaderboard](#the-live-leaderboard)
- [Past matches](#past-matches)
- [The match report](#the-match-report)
- [Using it in rules](#using-it-in-rules)
- [Permissions](#permissions)

***

Who is on top right now, and what happened in every match CRCON recorded.

## Turning it on

Install **Leaderboard and matches** from the server's
[Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
page. The rankings are the **Scoreboard** and **Squads** tabs of **Live**
(`/servers/:id/leaderboard`); past matches are **Community → Matches**
(`/servers/:id/matches`, or `/matches` for every server).

## The live leaderboard

![Scoreboard](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/leaderboard.png)

The top three players of every category and the best squads of every type,
as the current match stands, **refreshed every 10 seconds**. A strip on top
shows the map, the score, the sectors and the player count.

It reads the same player snapshot the rules are judged against, so it costs no
CRCON call of its own and shows exactly what a `{top_kills}` placeholder or a
*Position in kills* condition would see. If CRCON does not answer, the page
says so and keeps the last table.

**Player categories**, one card each: Kills, K/D, Kills / min, Combat,
Offense, Defense, Support, Vehicles (destroyed) and Teamwork (combat +
support). **Both teams / Allies / Axis** narrows every card to one side.

- K/D only counts players with at least **five kills**, and kills per minute
  only players with **five minutes** on the map, so a lucky start does not top
  the table.

**Squads** (the *Best squads* panel, or the **Squads** tab on its own) are
grouped by team and unit, typed from their members' roles the way CRCON does —
tank crew is **armor**, spotter and sniper are **recon**, artillery roles are
**artillery**, everything else **infantry** — and ranked within their type by
the sum of their members' four scores. Each shows its leader, or *no leader*.
The commander is not a squad.

**Send the scoreboard to the chat** (needs `manage_servers`) asks for
confirmation, then posts the top three in kills, combat, support and defense
to the game chat.

## Past matches

![Matches](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/matches.png)

Read straight from **CRCON's own match history**. CRCON records a match when
it ends, so a new server shows nothing until the first one finishes.

- Filter by server, **Map**, **Mode** and the **last 7, 30 or 90 days**
  (30 by default).
- Matches are grouped by day (*Today*, *Yesterday*…), with what each server
  is playing **now** on top.
- Each row: map, server, start, duration, *Allies × Axis*, the result, the
  player count and the MVP. **Load more** brings the next ones.
- Beside the list: the period in numbers (matches, average length, which side
  wins), the most played maps, and a shortcut to the rule that posts match
  summaries to Discord.
- **Export CSV** downloads the list.

## The match report

![Match report](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/match.png)

One page answers *"what happened last night"*:

- the **result** — map, mode, start and end, score, sectors — with the
  match's kills, vehicles destroyed, rules fired and team kills
- the **MVP of the match**, and the VIP a rule gave them, if any
- **Best by category** and **Best squads**, ranked exactly the way the live
  leaderboard ranks
- **Rules that fired in this match**, from this app's own history (up to five
  minutes after the end), with a link to the full history
- the **Full scoreboard** — All / Allies / Axis, with *Find a player* — kills,
  deaths, K/D, combat, offense, defense, support

**Export CSV** downloads the scoreboard; **Post on Discord** (needs
`manage_rules`) posts the report to a channel after asking.

> [!NOTE]
> The squad and role come from CRCON's stored unit history, which saves a
> player in no squad as squad 0. Unassigned players are therefore counted in
> Able — a limit of the stored history, not of this page.

## Using it in rules

Rules read the same rankings:

- **Conditions:** *Position in kills*, *Position in K/D ratio*, *Their squad's
  position among its type*… (1 is the best)
- **Placeholders:** `{top_kills}`, `{top_support}`… and
  `{top_armor_squads}`, `{top_infantry_squads}`… each become the top three as
  one line, e.g. `Ana (30), Bo (22), Cy (19)`

See [If — conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions).

## Permissions

| Permission | Grants |
| --- | --- |
| `view_stats` | *See matches, players and leaderboards* — also the [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) pages |
| `manage_servers` | **Send the scoreboard to the chat** |
| `manage_rules` | **Post on Discord** from a match report |

---

***

**←** [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) **→**
