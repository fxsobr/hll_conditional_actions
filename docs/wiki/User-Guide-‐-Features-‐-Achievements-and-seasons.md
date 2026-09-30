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
[Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
page. The pages are **Seasons** and **Achievements**, the first tabs of
**Community** in the icon rail (`/seasons`, `/servers/:id/achievements`).

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

**Community → Achievements** (`/servers/:id/achievements`) is the server's
gallery: every achievement with the share of players who have it and how many
times it was unlocked, marked *Simulation* or *Off* when it is. Narrow it by
tier (Bronze, Silver, Gold, Legendary) and by **In the match** / **Over the
career**. Beside it: the **latest unlocks**, and the **starter set**.

An achievement belongs to one server. **New achievement** asks for:

| Section | Fields |
| --- | --- |
| **Identity** | Name (up to 60 characters), tier, description (up to 140), icon. The game cannot show emoji: they are removed. Tiers show in game as `[*]` to `[****]` |
| **When it unlocks** | **Match** or **Career**, the metric, *at least* the goal (e.g. 20 kills), and the server it counts on |
| **Reward and behaviour** | VIP hours (0 gives none), a flag on the CRCON profile (up to 8 characters, never shown in game), **Announce in game** (on by default), **Start in simulation** (record who unlocks it, send nothing), **Active** |

**Metrics** — in one match or over a career: kills, combat, offense, defense,
support, teamplay (combat + support), vehicles destroyed, minutes played.
Career only: matches played, matches as commander, matches leading a squad.
A commander or squad-leader match counts when the player ended it in that
role after at least twenty minutes.

The **live preview** beside the form shows the medal, **how it looks in
game**, and — read from the last matches in CRCON's history — how many
players would reach the goal, from *Common* to *Nobody reached it*, and **who
would already have it**.

The player receives a private message with the tier, name, description and
`+VIP Nh`; VIP and the flag are granted through the same actions rules use.

**Install the set** (the *Starter set* panel) creates twelve achievements
(First blood, Sharpshooter, Medic's pride, Tank buster, Veteran, Thousand
kills, Voice of the team, Squad leader, Regular, Iron wall, Spearhead,
Legend), all **in simulation**, so you see what they would do before
rewarding anybody.

A player's achievements also show on their
[player page](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players).

## Seasons

![Seasons](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/seasons.png)

**Community → Seasons** opens straight on the running season (or the newest
one). **Earlier seasons** lists the others, running or finished.

**The season's page:**

- **Where it stands** — *Day N of M*, when it ends, how many win how much VIP,
  the minimum matches and how many take part.
- **The podium** — the top three qualified players, with how far each moved
  this week.
- **The standings** — rank, player, matches, the score and the **week**
  column: places gained or lost since a week ago, or *new*. A **prize line**
  is drawn under the last winner, and the first player below it reads how
  many points they are from the podium. Players short of the minimum read how
  many more matches they need to count. *Find a player* searches; 12 rows,
  then **Show all**.
- **How the score is made** — the formula in words.
- **When it closes** — the reward, the announcement, and whether the next
  season opens on its own.

The weekly movement compares today's rank with the ranks saved at least seven
days ago (or the earliest ones, for a season younger than a week).

**Close now** ends the season early and rewards the current top players;
**Remove** deletes it with its standings.

**New season** (`/seasons/new`):

| Field | Notes |
| --- | --- |
| Name | Up to 60 characters |
| Length | 7, 14, 30 or 60 days, or up to 365 |
| Starts at | Now, or a date |
| Servers | One, or several **of the same game** — one season for a community's three servers |
| Renew on its own | Open the next season of the same length when this one closes |
| Scoring | See below |
| Prize | **Winners** 1 to 50 (default 3), **Minimum matches** to qualify (default 3), **VIP hours** for each winner on every server of the season (default 168) |

**Scoring:**

| Method | What it does |
| --- | --- |
| **Sum** | Adds one stat up, match after match. Rewards whoever plays the most |
| **Average** | One stat divided by matches played. Rewards playing well; the minimum matches keeps one lucky game from winning |
| **Weighted** | Each stat you pick — kills, combat, offense, defense, support, vehicles destroyed — times its weight (by default combat 1, support 0.6, defense 0.4, offense 0.3). Tick **Divide by the matches played** for a per-match score |
| **Elo** | A rating driven by results and performance. Everybody starts at 1000 |

An **Elo** season starts from a preset — *competitive* (team result only),
*balanced* or *performance* (mostly what the player did) — and every piece is
tunable: result as win/draw/loss or sectors held, how much comes from the
result versus performance, K fixed or decreasing, placement matches, no gain
on a loss, minimum minutes and time scaling, caps, a floor, and a weekly
**decay** after two weeks without playing. Ratings are shown in tiers from
bronze to legend.

The **standings preview** applies the formula to the last ten matches of each
server in CRCON's history and shows who would lead — and, for a running
season, who would pass whom. Nothing is saved until you create it. Changing
the scoring of a running season counts from the next match on.

When a season ends, the top qualified players get VIP, the winners are
announced in game, and — if it renews — the next season starts right away.

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
- Use **Average**, or **Weighted** divided by the matches, with a sensible
  minimum for short seasons, so the winner is not simply whoever played the
  most. The standings preview shows the difference before you commit.

---

***

**←** [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) **→**
