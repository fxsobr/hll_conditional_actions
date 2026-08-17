🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) / [Rules ‐ If (conditions)](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions)
***

# Rules ‐ If (conditions)

## Menu

- [How a condition is built](#how-a-condition-is-built)
- [General](#general)
- [The player](#the-player)
- [The squad](#the-squad)
- [This match](#this-match)
- [Their history](#their-history)
- [The server](#the-server)
- [The clock](#the-clock)
- [The event](#the-event)
- [What happens when a value is unavailable](#what-happens-when-a-value-is-unavailable)

***

## How a condition is built

Three parts: **field**, **operator**, **value**.

> `Player level` · **is less than** · `10`

The field decides which operators are offered — you cannot ask whether a
number *starts with* something. The complete operator reference, with an
example of each, is on
[Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators).

Add as many as you like; the combinator at the top of the step says whether
**all** or **any** of them must hold.

## General

| Field | Type | What it is |
| --- | --- | --- |
| **Always** | yes/no | Matches everything. What a rule with no real condition uses |
| **Times this rule already hit this player** | number | How many times *this* rule has fired for this player. `is 0` means "the first time only" |

## The player

| Field | Type | What it is |
| --- | --- | --- |
| **Player name** | text | The in-game name |
| **Player ID** | text | The platform id (Steam64 or the Windows Store id) |
| **Level** | number | In-game level |
| **Is VIP** | yes/no | Whether CRCON has them as VIP on this server |
| **Role** | text | Their current role. The options follow the game — HLL and HLL: Vietnam have different lists |
| **Team** | text | Allies or Axis, named per game |
| **Squad** | text | The unit name: `able`, `baker`, `command`… |
| **Clan tag (in-game field, not the name)** | text | Exactly what the label says: the game's own clan tag field, which is not the brackets people type into their name. A player calling themselves `[ABC] Name` has an **empty** clan tag — match those with `Player name` **contains** `[ABC]` instead |
| **Platform** | text | Where the account comes from — Steam, Windows Store |

## The squad

Everything here is about the squad the player is in *at that moment*.

| Field | Type | What it is |
| --- | --- | --- |
| **Is the squad leader** | yes/no | They hold the officer/leader role |
| **Is the commander** | yes/no | They are the team's commander |
| **Squad has a leader** | yes/no | Somebody in their squad holds the leader role. The field behind every "squad without an officer" rule |
| **Squad size** | number | How many players are in it |
| **Is in an armor squad** | yes/no | Their squad is an armour squad |
| **Is alone in an armor squad** | yes/no | Armour squad, one player. The "solo tank" field |

These cost nothing extra: they are read from the same player list the app
already fetches, not from another call to CRCON.

## This match

Reset every map.

| Field | Type | What it is |
| --- | --- | --- |
| **Kills** | number | Kills this match |
| **Deaths** | number | Deaths this match |
| **K/D ratio** | decimal | Kills divided by deaths |
| **Team kills** | number | Team kills this match |
| **Combat score** | number | The in-game combat score |
| **Offense score** | number | Offense score |
| **Defense score** | number | Defense score |
| **Support score** | number | Support score |
| **Kills per minute** | decimal | Kills divided by minutes played this map. A rate, so it is not skewed by a long round |
| **Deaths per minute** | decimal | Same, for deaths |
| **Time on this map (seconds)** | number | How long they have been on this map |

## Their history

Across every match CRCON has recorded, not just this one.

| Field | Type | What it is |
| --- | --- | --- |
| **Total playtime (seconds)** | number | Lifetime playtime on your servers |
| **Sessions played** | number | How many times they have connected. `is 1` is a genuinely new player |
| **Penalties received** | number | Punishments recorded against them |
| **Flags** | list | The flags an admin has put on them in CRCON. Only **contains** and **does not contain** apply |

> [!NOTE]
> These come from the player's CRCON profile, which is one extra API call.
> The app only makes it when a rule actually asks for one of these fields.

## The server

| Field | Type | What it is |
| --- | --- | --- |
| **Players on the server** | number | Total connected |
| **Players on the allied team** | number | |
| **Players on the axis team** | number | |
| **Players on the same team** | number | On *this player's* team — the one to use for "my team is short" |
| **Team difference (players)** | number | How lopsided the teams are, as a positive number |
| **Allied score** | number | Match score |
| **Axis score** | number | Match score |
| **Players in queue** | number | Waiting to get in |
| **Map** | text | The current map |
| **Game mode** | text | Warfare, Offensive, Skirmish… per game |
| **Match time remaining (seconds)** | number | Useful for end-of-round rules that should not need the match-end trigger |

## The clock

The server's own timezone, set on the server page — so "after 22:00" means the
players' local evening, and it follows daylight saving.

| Field | Type | What it is |
| --- | --- | --- |
| **Hour of day (0-23)** | number | `is at least 22` is the evening |
| **Day of the week** | text | Monday…Sunday |

## The event

Only carry a value on the triggers that produce them; the builder hides them
on the others.

| Field | Type | Available on |
| --- | --- | --- |
| **Chat message** | text | chat, chat command |
| **Chat scope** | text | chat, chat command — unit, team or all |
| **Chat team** | text | chat, chat command |
| **Command** | text | chat command — the word after `!`, `@` or `#` |
| **Command arguments** | text | chat command — everything after it |
| **Weapon** | text | kill, death, team kill |
| **Other player** | text | kill, death, team kill — the player at the other end |
| **Event type** | text | The raw kind of event, for the rare rule that needs it |

## What happens when a value is unavailable

A condition whose value cannot be read **does not match**. It does not crash
the rule and it does not count as true.

That matters most in two places:

- **On connect**, before the delay has passed, level and clan tag are not
  known yet. This is why the connect trigger waits.
- **A field belonging to another trigger** — asking for `Weapon` on a connect
  rule — is always unavailable, so the rule never fires. The builder hides
  those fields to stop it happening; a rule imported from elsewhere can still
  carry one.

If a rule never seems to fire, the rule's page flags it: *"This rule has been
enabled for a while and has never matched anything."* Usually one condition is
stricter than intended.

***

**←** [Rules · When](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Rules · Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) **→**
