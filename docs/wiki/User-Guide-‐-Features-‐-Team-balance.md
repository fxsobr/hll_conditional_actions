🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Team balance](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Team-balance)
***

# Team balance

> **Simulation only.** The module measures every match and works out who
> it *would* move. Nobody is switched yet: the plans are there to be judged
> before anything acts for real.

## Menu

- [Why](#why)
- [The balance rating](#the-balance-rating)
- [Groups that move together](#groups-that-move-together)
- [The plan at the end of a match](#the-plan-at-the-end-of-a-match)
- [The page](#the-page)
- [The simulator](#the-simulator)
- [Settings](#settings)
- [First install](#first-install)

## Why

In a community where the same clans play every night, one side tends to be
stacked. Measured on 45 days of a busy community's matches:

- most full Warfare matches ended **5-0**
- on the next map the game swaps the factions, but **9 in 10 winners stay
  together** on one team, and that group **wins again 62%** of the time
- the side whose players were rated 40+ points higher won **93%** of the
  time

So the stack has to be broken up as a group of players, not as a faction.

## The balance rating

Every player gets a rating, worked out like an Elo season's (the
*balanced* preset of [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons)):
the team's result, the sectors held and the player's own performance
against their team. Unlike a season, it **never resets**.

A player with few matches counts closer to 1000 (a tenth of the way per
match, in full after 10), so one lucky match does not make a newcomer a
star.

It learns from CRCON's match history: every few minutes the matches that
ended are read, with each player's squad and the result.

## Groups that move together

The balance never splits:

- **a squad** — it moves whole or not at all
- **frequent partners** — two players who finished 3+ matches in the same
  squad (configurable) count as one group, even if they ended up in two
  squads this time

A group with the **commander** never moves.

Moving a squad has a cost the game imposes: a switched player lands with no
squad (RCON cannot put anybody in one), and the leader has to make it again.
That is why the plan prefers small groups and players with no squad.

## The plan at the end of a match

When a match ends, the module takes the two teams, their average ratings and
the gap between them.

- Under the **trigger** (15 points by default) the match is *balanced*.
- Above it, a plan moves or swaps groups — the one that closes the gap most
  first — until the gap is under half the trigger, within the **most players
  moved** and with the head counts at most **2** apart.

Since the game swaps the factions on the next map, a plan says "from the
Allies **to the other team**", not to a faction.

When the next match ends, the plan is marked with whether the stronger team,
together again, **won again** — what the balance is meant to stop.

Replayed on 799 real matches, plans like these brought 85–91% of them under
10 points, moving a median of 4–5 players.

## The page

**Community → Balance** (`/balance`):

| Part | What it shows |
| --- | --- |
| **Numbers** | Matches measured in the last 7 days, how many were unbalanced, the average gap and with the plans, and how often the stronger team won again |
| **Right now** | Each server's teams with their average rating and the gap, read from CRCON |
| **Match by match** | Every match: map, result, both teams' ratings, *Balanced* or *Would move N*; open one for the groups and players |
| **Settings** | Per server — see below |

Viewing it takes `view_progression`; changing the settings,
`manage_progression`.

## The simulator

**Community → Balance → Simulator** replays the balance over past matches
with settings you pick, to choose them on evidence. It compares four ways of
deciding when a match gets a plan:

| Rule | Acts when |
| --- | --- |
| **Rating gap** | The teams' average ratings are at least *Unbalanced from* apart |
| **Previous match** | The match before had a dominant winner — at least the set share of the loser's kills or points — and enough of those winners are on one side again |
| **Both** | Both of the above |
| **Either** | Either of the above |

For each it shows how many matches it acts on, how many of the fast
matches (over in 30 minutes) and of the **repeated stomps** (the previous
match's dominant winners, together again, winning again) it catches, the
gap and the stronger side's chance before and after, and how many players
it moves. *Who would pay for it* lists the players a rule would move most.

*Does the rating predict?* shows, for each band of gap, how often the
stronger side won and how often the match was over in 30 minutes — the
table the chances are read from.

Two sources of matches:

- **History** — CRCON's matches with today's ratings. Months of data, but
  optimistic: the ratings already learned from those results.
- **Measured live** — the plans the module recorded, with the ratings they
  had then (every plan keeps the roster it saw since 0.5.0). Honest, and
  growing with every match.

*Extra points for the previous winners* counts the previous dominant group
as that much stronger when planning, so the plan breaks the group up rather
than only evening the averages.

## Settings

| Setting | Default | |
| --- | --- | --- |
| **Unbalanced from** | 15 points | The gap from which a match gets a plan; the plan aims for half |
| **Most players moved per match** | 12 | |
| **Most extra players on one team** | 2 | |
| **Matches in one squad to count as a group** | 3 | |
| **Post each unbalanced match on Discord** | — | A [webhook](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) for the plans |

## First install

The ratings start empty. **Learn from the history again** reads the latest
500 matches of every server with the module from CRCON and learns from them
in order — a few minutes, in the background. It can be run again at any time;
it starts from scratch.

***

**←** [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Live cockpit and feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) **→**
