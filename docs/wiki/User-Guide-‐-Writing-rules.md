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

**Rules → New rule** (`/rules/new`), or **Ready-made recipes** to start from
one. The builder is a test bench: it reads the rule back as a sentence and
tests it against real events while you type.

![The rule builder](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule-builder.png)

**Recent runs** — the last times the trigger happened, as a strip. Click one
and every condition shows the value it read and whether it passed.

**The 7-day replay** — the rule as typed, run over the last week of real
events next to the published version: how many times it would fire, for which
players, and who changed fate with your edits.

**Try it** — at the bottom of the builder, against a saved event or a player
who is connected right now. Nothing is sent to the game.

**Simulation** — the rule is published **in simulation**: it is evaluated,
rate limited and recorded in the history exactly as usual, with the messages
it *would* have sent rendered in full, but no call reaches CRCON. After three
clean days its page says **Ready to act for real** and offers **Go live for
real**.

All of it in detail:
[Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules).

## Time windows

`Hour of day` and `Day of the week` read the server's configured time zone, so
a rule follows your players' local time and daylight saving. A window that
crosses midnight is two conditions in a group set to **any**: `hour ≥ 22` or
`hour ≤ 2`.

## Sharing rules

**Export JSON** on the Rules page downloads the rules currently listed (the
filters apply), or the ones you selected; **Import** takes that file back (up
to 2 MB). A single rule's **Definition** tab exports it on its own.

What travels is the rule itself — trigger, conditions, actions, limits and
game. What does not: the server it was pinned to, since an id from another
install means nothing, so the importer asks where the rules should land (*Pin the imported rules to* a server, or every server
running their game).

Imported rules always arrive **disabled**. An invalid rule anywhere in the file
imports nothing at all, rather than leaving half a rule set behind.

## Example

> **Warn repeat team killers**
> *When* a player team kills · *if* team kills ≥ 3 **and** players on the server
> ≥ 40 · *then* message the player *"{player_name}, that is {teamkills} team
> kills. The next one is a kick."* and send a Discord message · cooldown 120s.

---

***

**←** [The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) **→**
