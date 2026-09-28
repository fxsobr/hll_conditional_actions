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
[marketplace](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features).
The pages are **Leaderboard** (`/servers/:id/leaderboard`) and **Matches**
(`/servers/:id/matches`).

## The live leaderboard

The top players of every category and the best squads of every type, as the
current match stands, **refreshed every 20 seconds**.

It reads the same player snapshot the rules are judged against, so it costs no
CRCON call of its own and shows exactly what a `{top_kills}` placeholder or a
*Position in kills* condition would see. If CRCON does not answer, the last
table stays on screen.

**Player categories:** kills, K/D ratio, kills per minute, combat, offense,
defense, support, vehicles destroyed, teamplay (combat + support) and
offense + defense.

- K/D only counts players with at least **five kills**, and kills per minute
  only players with **five minutes** on the map, so a lucky start does not top
  the table.

**Squads** are grouped by team and unit, typed from their members' roles the
way CRCON does — tank crew is **armor**, spotter and sniper are **recon**,
artillery roles are **artillery**, everything else **infantry** — and ranked
within their type by the sum of their members' four scores. The commander is
not a squad.

## Past matches

![Matches](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/matches.png)

Read straight from **CRCON's own match history**: every match it recorded, with
map, mode, date, duration and result, twenty per page. CRCON records a match
when it ends, so a new server shows nothing until the first one finishes.

## The match report

![Match report](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/match.png)

One page answers *"what happened last night"*:

- the **result** and the **MVP** (best teamplay)
- **top players** and **top squads**, ranked exactly the way the live
  leaderboard ranks
- **what the rules did** while the match was played, from this app's own
  history
- the full **scoreboard** — kills, deaths, K/D, combat, offense, defense,
  support

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
| `view_stats` | *See matches, players and leaderboards* — also the player page `/players/:player_id` |

---

***

**←** [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Live feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) **→**
