🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Writing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules)
***

# Writing rules

## Menu

- [The reference pages](#the-reference-pages)
- [Trying a rule before trusting it](#trying-a-rule-before-trusting-it)
- [Time windows](#time-windows)
- [Sharing rules](#sharing-rules)
- [Example](#example)

***

A rule is one sentence: **when** something happens, **if** it matches, **then**
do this. This page is the walkthrough; each part has a reference page of its
own.

## The reference pages

| Page | What is in it |
| --- | --- |
| [Overview](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview) | Name, priority, group, scope, limits, escalation, simulation |
| [When — triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) | All eleven, what fires them, what each one makes available |
| [If — conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions) | Every field you can test, grouped |
| [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) | *is*, *contains*, *is one of*… each with examples |
| [Then — actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) | Every action, its parameters and the CRCON permission it needs |

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

***

**←** [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) **→**
