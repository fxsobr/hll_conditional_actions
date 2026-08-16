🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / [Writing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules)
***

# Writing rules

## Menu

- [1. When — the trigger](#1-when-the-trigger)
- [2. If — the conditions](#2-if-the-conditions)
- [3. Then — the actions](#3-then-the-actions)
- [4. Scope and limits](#4-scope-and-limits)
- [Trying a rule before trusting it](#trying-a-rule-before-trusting-it)
- [Time windows](#time-windows)
- [Sharing rules](#sharing-rules)
- [Example](#example)
- [Escalating repeat offenders](#escalating-repeat-offenders)

***

A rule has four parts.

## 1. When — the trigger

| Trigger | Fires |
| --- | --- |
| Player connects | Once, for that player, a few seconds later (see below) |
| Player disconnects | Once, for that player |
| Player gets a kill / dies / team kills | Once, for the player involved |
| Player writes in chat | Once, for the author |
| Player types a chat command | Once, for the author, when the message opens with `!`, `@` or `#` |
| Player switches team | Once, for that player |
| Match starts / ends | Once for **every** connected player |
| On a schedule | Every N seconds, for every connected player |

A single `KILL` log line fires both `player kill` (for the killer) and
`player dies` (for the victim), matching CRCON's own behaviour. A chat line
starting with a command prefix likewise fires both `player writes in chat` and
`player types a chat command` — the second one hands you the parsed `command`
(`!vip please` → `vip`) and `command arguments` (`please`) instead of making
you match the raw text.

**A connect is handled about five seconds late, on purpose.** When the game
server reports `CONNECTED`, the player does not exist in `get_detailed_players`
yet, so their level, clan tag, team and stats would all read as unavailable and
any condition on them would be false. Waiting is what makes a welcome rule fire
for everyone rather than for whoever happened to be in the last snapshot. Tune
it with `CONNECT_DELAY_MS` if your server is slower or faster.

## 2. If — the conditions

Conditions are `field operator value`, combined with **and**, **or**, **nand**
or **nor**. Fields cover the player (name, level, VIP, role, team, squad), the
squad and role (squad size, whether it has a leader, whether the player leads
it or commands, whether they are alone in an armor squad), the match (kills,
deaths, K/D, scores, per-minute rates, playtime), their history (sessions,
total playtime, penalties, flags), the server (player counts per team, how
lopsided the teams are, scores, map, game mode, time remaining) and the event
itself (chat message, command, weapon, other player).

The squad fields are read from the `get_detailed_players` snapshot the engine
already fetches each cycle — the same data CRCON builds its own team view
from — so a "squad without an officer" rule costs no extra API call.

Two things narrow the list as you build:

- **the trigger** — `weapon` only exists on a kill event, so it is not offered
  on a `player connects` rule (and is rejected if you try);
- **the game** — role, team and game mode values come from that game's profile,
  so a Vietnam rule offers `Squad Leader` and `Pilot` while a WW2 rule offers
  `Officer` and `Artillery Observer`.

Anything the current snapshot cannot answer evaluates to false. A rule never
fires on incomplete data, which matters when the action is a ban.

> **`Clan tag` is not the tag in the player's name.** It is the game's own
> clan tag field, which most players never set, so it is usually empty. If your
> community writes its tag into the player name (`ャ MadMax`), match on
> **`Player name`** instead — a `clan tag does not contain ャ` condition is true
> for everybody, because their clan tag is blank.

## 3. Then — the actions

Messaging (`message the player`, `message every player`, `set the broadcast`,
`broadcast temporarily`, `set the welcome screen`), punishment (`punish`,
`kick`, `temp ban`, `perma ban`, `switch team now`, `switch team on death`),
bookkeeping (`add`/`remove flag`, `add`/`remove from watchlist`) and
`send a Discord message`.

Any text field accepts placeholders, using the same syntax as CRCON's message
templates:

```
Welcome {player_name}! You are level {player_level} playing {player_role} on {map_name}.
```

Available: `player_name`, `player_id`, `player_level`, `player_role`, `team`,
`unit_name`, `clan_tag`, `kills`, `deaths`, `teamkills`, `combat`, `offense`,
`defense`, `support`, `is_vip`, `playtime_minutes`, `map_name`, `game_mode`,
`server_name`, `server_player_count`, `weapon`, `target_player_name`,
`message`.

An unknown placeholder is left visible in game rather than silently blanked, so
a typo is obvious.

## 4. Scope and limits

- **Applies to** — one specific server, or every enabled server of that game.
  One rule can cover a whole fleet.
- **Priority** — higher runs first.
- **Cooldown per player** — minimum seconds between two runs for the same
  player.
- **Maximum times per player per day** — a cap within a rolling 24 hour window.

Both limits use the `rule_executions` table, which is also the audit log you
browse under **History**.

## Trying a rule before trusting it

Two things make it safe to write a rule that kicks or bans.

**Try it** — at the bottom of the builder, pick a server and a player who is
connected right now. The rule *as currently typed*, unsaved edits included, is
evaluated against them and you get a table showing each condition's expected
value, its actual value, and whether it held. Nothing is sent to the game.

**Simulation** — a switch on the rule itself. A rule in simulation is
evaluated, rate limited and recorded in the history exactly as usual, with the
messages it *would* have sent rendered in full, but no call reaches CRCON.
Leave it on for a day, read the history, then switch it off.

## Time windows

`Hour of day` and `Day of the week` read the server's configured time zone, so
a rule follows your players' local time and daylight saving. A window that
crosses midnight is two conditions combined with **Any condition may hold**:
`hour ≥ 22` or `hour ≤ 2`.

## Sharing rules

**Export** downloads the rules currently listed (the filters apply) as JSON;
**Import** takes that file back. What travels is the rule itself — trigger,
conditions, actions, limits and game. What does not: the server it was pinned
to, since an id from another install means nothing, so the importer asks where
the rules should land.

Imported rules always arrive **disabled**. An invalid rule anywhere in the file
imports nothing at all, rather than leaving half a rule set behind.

## Example

> **Warn repeat team killers**
> *When* a player team kills · *if* team kills ≥ 3 **and** players on the server
> ≥ 40 · *then* message the player *"{player_name}, that is {teamkills} team
> kills. The next one is a kick."* and send a Discord message · cooldown 120s.

---

## Escalating repeat offenders

By default every action of a rule runs every time it fires. Set **escalate
repeat offenders** (in *Limits*) to a number of seconds and the action list
becomes a ladder instead: the engine counts how many times the rule already
fired for *that player* inside the window and runs only the matching step.

| Actions | 1st offence | 2nd | 3rd | 4th and beyond |
| --- | --- | --- | --- | --- |
| message, message, punish, kick | message | message | punish | kick |

Past the end of the list the last step repeats, so "…and keep kicking" needs
no special case. The count comes from the execution history rather than from
memory, so a restart does not hand a repeat offender a clean slate, and the
window rolls — stop offending for long enough and the ladder resets itself.

This is one rule, not four. The same count is also available as the
`times this rule already hit this player` condition, if you would rather
branch on it than escalate.
