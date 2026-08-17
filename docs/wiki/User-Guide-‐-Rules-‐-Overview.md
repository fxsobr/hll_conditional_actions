🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / Rules / [Overview](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview)
***

# Rules ‐ Overview

## Menu

- [The four steps](#the-four-steps)
- [Setup](#setup)
- [Priority — which rule runs first](#priority)
- [Group — switching a set together](#group)
- [Game and Applies to](#game-and-applies-to)
- [Enabled and Simulation only](#enabled-and-simulation-only)
- [How conditions combine](#how-conditions-combine)
- [Limits](#limits)
- [Escalation](#escalation)
- [Where to go next](#where-to-go-next)

***

A rule is one sentence: **when** something happens, **if** it matches, **then**
do this. Everything else on the page exists to say *how often*, *where*, and
*how hard*.

## The four steps

| Step | What it answers | Reference |
| --- | --- | --- |
| **Setup** | What is this rule, where does it run | this page |
| **When** | What wakes the rule up | [Triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) |
| **If** | What has to be true | [Conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions) · [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) |
| **Then** | What the app does about it | [Actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) |

A rule with **no conditions** fires every time its trigger does. That is a
legitimate rule — a welcome message is exactly that — not an unfinished one.

## Setup

| Field | What it is for |
| --- | --- |
| **Name** | Required. It appears in the history, in the metrics and in Discord messages, so name it after what it *does*: "Warn team killers", not "Rule 3" |
| **Priority** | Order among rules that answer the same event. See below |
| **Description** | Free text for the next admin. Nothing reads it but a person |
| **Group** | A label that lets rules be filtered and switched together. See below |

## Priority

**What it does:** decides which rule runs **first** when more than one answers
the same event.

**What it does not do:** stop the others. This is the part people get wrong.
Priority is not "first match wins" — every rule whose trigger fires and whose
conditions hold will run, whatever its priority. If two rules both kick, the
player is kicked twice.

A whole number, `0` by default. Higher goes first. Rules with the same number
run in the order they were created.

### What the order does *not* buy you

One rule cannot set something up for another rule **within the same event**.
Everything the conditions read — the player, their squad, their flags, the
server — is read **once, before any rule runs**, and every rule matching that
event sees that same picture.

So this does not work the way it looks:

| Priority | Rule | Then |
| --- | --- | --- |
| 10 | Flag clan members on a team kill | Add a flag `✅` |
| 0 | Punish anyone without `✅` | Punish the player |

The flag really is added first, but the punishing rule is still looking at the
picture taken before either ran — where the flag was not there yet. It punishes
anyway. The flag helps from the *next* event onwards.

Write the exemption as a condition on the punishing rule instead:

> `Player name` **does not contain** `[CB]`

One rule, no ordering, no window where it is wrong.

### When the order does matter

What priority really controls is the order things **reach the game**, and that
is worth getting right when a player is on the receiving end of two rules.

Two rules that both message on a team kill:

| Priority | Rule | Message |
| --- | --- | --- |
| **10** | Explain the rule | "Team killing is not allowed here." |
| **0** | Warn about the ladder | "That is your third. The next one is a ban." |

At those priorities the player reads the explanation and then the warning,
which is a sentence. Reversed, they read the threat and then a rule they have
already been threatened over.

The same applies when one rule messages and another kicks: put the message
above the kick, or it never arrives.

Most of the time the order does not matter and `0` everywhere is right.

> [!TIP]
> The builder tells you when another enabled rule answers the same trigger on
> the same servers. It is a heads up, not an error — two rules on one event is
> often exactly what you want, like warning the player *and* posting to
> Discord. It is there so that "both of them kick" is a decision rather than a
> surprise.

## Group

**What it does:** puts a label on a rule so a set of related rules can be
found, and switched, together. It changes nothing about how or when a rule
runs.

Type anything you like; the builder suggests names already in use so you do
not end up with both `Seeding` and `seeding`. Leaving it empty is fine.

### What you get on the Rules page

**A filter.** The group dropdown appears as soon as any rule has one, and
narrows the list to that set.

**One switch for the whole set.** Pick a group in the filter and a bar
appears:

> Acting on the whole group **Seeding**.  **[Enable all]** **[Disable all]**

That is the point of groups. A community that runs different rules while the
server is filling up can switch six seeding rules off with one click when it
is full, instead of finding each one.

Each rule is still toggled individually underneath, and each one is written to
the audit trail — so *"who turned the whole seeding group off"* has an answer
on the rule's **Changes** tab.

**A label on the row**, so the list reads as a handful of policies rather than
twenty loose rules.

### Groups that tend to appear

| Group | Holds |
| --- | --- |
| `Seeding` | Rules that only make sense on an empty server, switched off when it fills |
| `Anti-cheat` | Kill rate watching, suspicious name patterns |
| `Welcome` | Greetings, new player watching |
| `Events` | Rules for a one-off night, switched on and off as a set |
| `Discord` | Rules whose only action is posting somewhere |

## Game and Applies to

**Game** is `Hell Let Loose` or `Hell Let Loose: Vietnam`. It is not cosmetic:
the two games have different roles, teams, maps and modes, so the dropdowns in
the **If** step change with it. Changing the game on a rule that already has
conditions can leave a condition pointing at a role that does not exist in the
other game.

**Applies to** is either one server or **every server running this game**. A
fleet-wide rule runs on every enabled server of that game — including servers
you add later, which is what makes one rule cover a whole community.

## Enabled and Simulation only

Two switches that are easy to confuse:

| Switch | Off | On |
| --- | --- | --- |
| **Enabled** | The engine ignores the rule entirely. Nothing is evaluated, nothing is recorded | The rule is live |
| **Simulation only** | Actions really run against the game | Everything is evaluated and recorded in the history, with the messages it *would* have sent, but **nothing reaches the game** |

Simulation is the safe way to try a rule on real traffic. Read a day of
history, then turn it off.

Every rule created from a **recipe** starts in simulation on purpose.

## How conditions combine

The **If** step has one combinator for the whole list:

| Setting | Fires when |
| --- | --- |
| **All conditions must hold** (`and`) | Every condition is true |
| **Any condition may hold** (`or`) | At least one is true |
| **Not all conditions hold** (`nand`) | At least one is false |
| **No condition holds** (`nor`) | Every one is false |

`nand` and `nor` exist for the rules that are easier to write inside out —
"fire unless they are VIP *and* over level 50". Most rules use `and`.

## Limits

Three fields under **Limits**, all optional, all `0` meaning *no limit*.

| Field | What it stops |
| --- | --- |
| **Cooldown per player (seconds)** | The same rule firing again for the *same player* until the cooldown has passed. A welcome message with a 3600 s cooldown greets a reconnecting player once an hour, not on every reconnect |
| **Maximum times per player per day** | The rule firing more than N times for one player in a rolling **24 hours** |
| **Escalate repeat offenders (seconds)** | See below. This one changes *what* runs, not *whether* it runs |

Both limits are counted per **player**, from the recorded history — so a
restart or a redeploy does not hand anybody a clean slate. A rule that fires
without a player (a match-wide broadcast) is not limited by either.

> [!NOTE]
> A limit that skips a run still records it. The **History** shows the run
> with the reason it was skipped, so a quiet rule can be told apart from a
> rule whose conditions never match.

## Escalation

Leave **Escalate repeat offenders** at `0` and every action in the **Then**
list runs, every time.

Set a window and the list becomes a **ladder** instead: the engine counts how
many times this rule already fired for that player inside the window and runs
**only the matching step**.

```
actions: [warn, warn again, punish, kick]

1st offence   -> warn
2nd offence   -> warn again
3rd offence   -> punish
4th and after -> kick
```

Past the end of the list the last step repeats — which is what makes "…and
keep kicking" the ending rather than a special case. Stop offending for longer
than the window and the ladder resets on its own.

The count comes from the same history the limits read, so it survives a
restart.

## Where to go next

- [Triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) — every **When**
- [Conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions) — every field you can test
- [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) — *is*, *contains*, *is one of*…, each with examples
- [Actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) — every **Then**, with what it needs
