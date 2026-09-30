🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) / [Rules ‐ Overview](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview)
***

# Rules ‐ Overview

## Menu

- [The sentence](#the-sentence)
- [Details](#details)
- [Priority — which rule runs first](#priority)
- [Group — folders on the Rules page](#group)
- [Game and Applies to](#game-and-applies-to)
- [Off, simulating, live](#off-simulating-live)
- [How conditions combine](#how-conditions-combine)
- [Limits](#limits)
- [Escalation](#escalation)
- [Where to go next](#where-to-go-next)

***

A rule is one sentence: **when** something happens, **if** it matches, **then**
do this. Everything else on the page exists to say *how often*, *where*, and
*how hard*.

## The sentence

The builder writes a rule as a sentence, one row per part:

| Row | What it answers | Reference |
| --- | --- | --- |
| **When** | What wakes the rule up, and on which servers | [Triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) · [Applies to](#game-and-applies-to) |
| **If** | What has to be true | [Conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions) · [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) |
| **Then** | What the app does about it | [Actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) |
| **Protections** | How often, and who is never touched | [Limits](#limits) · [Escalation](#escalation) · [Exemptions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules#exemptions) |
| **Details** | What the rule is called and where it is filed | [below](#details) |

While you type, the builder tests the rule against real events — see
[Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules).

A rule with **no conditions** fires every time its trigger does (*always, no
conditions*). That is a legitimate rule — a welcome message is exactly that —
not an unfinished one.

## Details

| Field | What it is for |
| --- | --- |
| **Name** | Required. It appears in the history, in the metrics and in Discord messages, so name it after what it *does*: "Warn team killers", not "Rule 3" |
| **Group** | The folder the rule is filed in on the Rules page. See below |
| **Game** | See [Game and Applies to](#game-and-applies-to) |
| **Priority** | Order among rules that answer the same event. See below |
| **Description** | Free text for the next admin. Nothing reads it but a person |

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

**What it does:** files the rule in a folder, so a set of related rules can be
found, and switched, together. It changes nothing about how or when a rule
runs.

Type anything you like; the builder suggests names already in use so you do
not end up with both `Seeding` and `seeding`. Leaving it empty is fine.

### What you get on the Rules page

![Rules](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rules.png)

**Folders.** The list is grouped by folder, in name order, with *Without a
folder* last. Each folder says how many of its rules are live, and each rule
shows its state (*Live*, *Simulating*, *Paused*, *Draft*), where it applies,
how many times it ran in the last 7 days and when it last ran. With more than
ten rules, the calm folders start closed.

**One switch for the whole set.** The folder's menu has **Turn on every rule**
and **Turn off every rule**. A community that runs different rules while the
server is filling up can switch six seeding rules off with one click when it
is full, instead of finding each one. Selecting rows gives the same for any
set, plus **Move to folder**, **Export** and **Remove**.

Each rule is still toggled individually underneath, and each one is written to
the audit trail — so *"who turned the whole seeding group off"* has an answer
on the rule's **Versions** tab.

The list also filters by state (**Live**, **Simulating**, **Draft**,
**Paused**, **Failing** — a failure in the last 24 hours), searches by name or
action, sorts by runs in 7 days, priority, name, last run or failures, and
keeps a **Needs attention** card: failures, rules *ready to act*, drafts
waiting.

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
the **If** row change with it. Changing the game on a rule that already has
conditions can leave a condition pointing at a role that does not exist in the
other game.

**Applies to** (*When … on*) is either one server or **every server running
this game**. A fleet-wide rule runs on every enabled server of that game —
including servers you add later, which is what makes one rule cover a whole
community.

## Off, simulating, live

The builder's state switch has three positions:

| State | What the engine does |
| --- | --- |
| **Switched off** | Ignores the rule entirely. Nothing is evaluated, nothing is recorded |
| **Simulating** | Evaluates and records everything in the history, with the messages it *would* have sent, but **nothing reaches the game** |
| **Live** | Runs the actions against the game |

Simulation is the safe way to try a rule on real traffic. A new rule is
published **in simulation**, and every rule created from a **recipe** starts
there on purpose. After three clean days the rule's page offers **Go live for
real** — see
[Going live](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules#going-live).

A rule can also be **paused** for a while without switching it off — see
[Pausing a rule](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules#pausing-a-rule).

## How conditions combine

Conditions sit in **groups**. Each group decides how **its** conditions
combine, and the rule decides how **the groups** combine:

| Setting | Fires when |
| --- | --- |
| **all** (`and`) | Every one is true |
| **any** (`or`) | At least one is true |
| **not all** (`nand`) | At least one is false |
| **none** (`nor`) | Every one is false |

With one group, its setting is the whole story — the old *All conditions must
hold / Any condition may hold* list. Add a second group with **+ Group** and
the top line, *[all of / any of / not all of / none of] these groups hold*,
joins them:

```
any of these groups hold
  ├─ all of these hold:  Is VIP is yes · Level ≥ 50
  └─ all of these hold:  Clan tag is 7DV
```

fires for a VIP over level 50, **or** for anybody in 7DV.

`nand` and `nor` exist for the rules that are easier to write inside out —
"fire unless they are VIP *and* over level 50". Most rules use `all`.
**see as an expression** shows the same logic as text, and the rule's
**Definition** tab can edit it that way.

## Limits

Under **Protections**, all optional, all `0` meaning *no limit*.

| Field | What it stops |
| --- | --- |
| **Wait between firings** (cooldown per player) | The same rule firing again for the *same player* until the cooldown has passed. A welcome message with a 3600 s cooldown greets a reconnecting player once an hour, not on every reconnect |
| **Daily cap** (times per player per day) | The rule firing more than N times for one player in a rolling **24 hours** |
| **Forget an offence after** (the escalation window) | See below. This one changes *what* runs, not *whether* it runs |

Both limits are counted per **player**, from the recorded history — so a
restart or a redeploy does not hand anybody a clean slate. A rule that fires
without a player (a match-wide broadcast) is not limited by either.

> [!NOTE]
> A limit that skips a run still records it. The **History** shows the run
> with the reason it was skipped, so a quiet rule can be told apart from a
> rule whose conditions never match.

## Escalation

By default every action in the **Then** row runs, every time.

Click **turn into a ladder** and the list becomes a **ladder** instead, with
**Forget an offence after…** as its window: the engine counts how many times
this rule already fired for that player inside the window and runs **only the
matching step**. **run every action instead** turns it back.

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
restart. The rule's page draws the ladder with how many times each step ran
(or would have, in simulation).

## Where to go next

- [Triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) — every **When**
- [Conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions) — every field you can test
- [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators) — *is*, *contains*, *is one of*…, each with examples
- [Actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) — every **Then**, with what it needs

***

**←** [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Rules · When](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers) **→**
