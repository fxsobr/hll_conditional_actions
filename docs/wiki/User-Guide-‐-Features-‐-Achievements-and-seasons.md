🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons)
***

# Achievements and seasons

## Menu

- [Turning it on](#turning-it-on)
- [When things are counted](#when-things-are-counted)
- [Achievements](#achievements)
- [Seasons](#seasons)
- [Showing it in game](#showing-it-in-game)
- [In the background](#in-the-background)
- [Permissions](#permissions)
- [Tips](#tips)

***

What players earn by playing, over time: **achievements** are goals with a
reward, **seasons** are leaderboards over a stretch of days whose top players
get VIP when they end.

## Turning it on

Install **Achievements and seasons** from the server's
[marketplace](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features).
The pages are **Achievements** (`/servers/:id/achievements`) and **Seasons**
(`/servers/:id/seasons`).

## When things are counted

Everything happens at **the end of a match**. The app takes the final player
stats of the match and, for each player who played **at least five minutes**:

1. adds the match to their career totals on that server
2. unlocks the achievements they reached, delivers the rewards, and announces
   the match's unlocks to everybody in one message
3. adds the match to every running season the server is part of

Somebody who joined as the match ended earns nothing.

## Achievements

![Achievements](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/achievements.png)

An achievement belongs to one server. **New achievement** asks for:

| Field | Notes |
| --- | --- |
| Name, description, icon | Name up to 60 characters. The game cannot show emoji: they are removed |
| Tier | Bronze, silver, gold, legendary — shown in game as `[*]` to `[****]` |
| Counted | **In one match** or **over the career** on this server |
| Metric and goal | e.g. 20 kills |
| VIP (hours) | 0 gives no VIP |
| Flag on the CRCON profile | Up to 8 characters. Only on the CRCON profile: the game never shows it |
| Announce to everybody in game | On by default |
| Simulation | Record who unlocks it, send nothing |
| Enabled | |

**Metrics** — in one match or over a career: kills, combat, offense, defense,
support, teamplay (combat + support), vehicles destroyed, minutes played.
Career only: matches played, matches as commander, matches leading a squad.
A commander or squad-leader match counts when the player ended it in that
role after at least twenty minutes.

The form's **live preview** reads the last matches from CRCON's history and
shows how many players would reach the goal — from *Common* to *Nobody reached
it* — and, for a career goal, who would already have it.

The player receives a private message with the tier, name, description and
`+VIP Nh`; VIP and the flag are granted through the same actions rules use.

**Add the starter set** creates nine achievements (First blood, Sharpshooter,
Medic's pride, Tank buster, Veteran, Thousand kills, Voice of the team, Squad
leader, Regular), all **in simulation**, so you see what they would do before
rewarding anybody.

The gallery shows every achievement with how many players have it, and the
latest unlocks. A player's achievements also show on their player page
(`/players/:player_id`).

## Seasons

![Seasons](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/seasons.png)

**Seasons → New season**:

| Field | Notes |
| --- | --- |
| Name | Up to 60 characters |
| Where it counts | One server, or several **of the same game** — one season for a community's three servers |
| How players are ranked | See below |
| How long it lasts | 1 to 365 days; it starts now |
| Winners | Top 1 to 50 |
| Min. matches | Players below it do not qualify (default 3) |
| Reward | VIP hours for each winner, on every server of the season (default 168) |
| Renews | Start the next season of the same length as soon as this one ends |

**How players are ranked:**

| Method | What it does |
| --- | --- |
| **Total of one stat** | Adds one stat up, match after match. Rewards whoever plays the most |
| **Average per match** | The stat divided by matches played. Rewards playing well; the minimum matches keeps one lucky game from winning |
| **Combined score** | Each of kills, combat, offense, defense, support and vehicles destroyed times the weight you give it |
| **Elo rating** | A rating driven by results and performance |

An **Elo** season starts from a preset — *competitive* (team result only),
*balanced* or *performance* (mostly what the player did) — and every piece is
tunable: result as win/draw/loss or sectors held, how much comes from the
result versus performance, K fixed or decreasing, placement matches, no gain
on a loss, minimum minutes and time scaling, caps, a floor, and a weekly
**decay** after two weeks without playing. Ratings are shown in tiers from
bronze to legend.

A season's page shows the standings and who is in line for the reward; once it
closes, who won. An admin can close it early or remove it.

When a season ends, the top qualified players get VIP, the winners are
announced, and — if it renews — the next season starts right away.

## Showing it in game

Rule messages can use these placeholders:

| Placeholder | Becomes |
| --- | --- |
| `{achievements}` | The player's achievements |
| `{achievements_count}` | How many they have |
| `{season_rank}` | Their position and score in the running season, e.g. `#4 (1210)` |
| `{season_top}` | The top five of the running season |

A chat command rule that answers `!rank` with `{season_rank}` is the usual
way to let players check.

## In the background

| Job | When | What |
| --- | --- | --- |
| `FinalizeSeasons` | every 5 minutes | Closes seasons whose time is up, rewards and announces winners, starts the next one; decays idle Elo ratings |
| Match end | at every match end | Totals, unlocks and season scores |

## Permissions

| Permission | Grants |
| --- | --- |
| `view_progression` | *See seasons and achievements* |
| `manage_progression` | *Run seasons and edit achievements* |

## Tips

- Start achievements in simulation and read the unlocks for a few days before
  switching rewards on.
- Use **Average per match** with a sensible minimum for short seasons, so
  the winner is not simply whoever played the most.

---

***

**←** [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) **→**
