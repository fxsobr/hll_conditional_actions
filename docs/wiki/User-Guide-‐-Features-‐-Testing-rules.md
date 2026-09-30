🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules)
***

# Testing rules

## Menu

- [Saved events](#saved-events)
- [The builder is a test bench](#the-builder-is-a-test-bench)
- [The 7-day replay](#the-7-day-replay)
- [Try it](#try-it)
- [The event simulator](#the-event-simulator)
- [Why didn't it fire?](#why-didnt-it-fire)
- [Simulation mode](#simulation-mode)
- [Going live](#going-live)
- [Drafts and versions](#drafts-and-versions)
- [Pausing a rule](#pausing-a-rule)
- [Exemptions](#exemptions)
- [Permissions](#permissions)

***

Everything that lets you trust a rule that kicks or bans before it touches a
real player. All of it comes with the **Conditional rules** module.

![The rule builder](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule-builder.png)

## Saved events

The app keeps real events for **7 days, up to 2,000 per trigger on each
server** — a quiet trigger covers the whole week, a busy one (kills) its
newest 2,000. They are what the builder's run strip and replay, *Try it*, the
simulator and *Why didn't it fire?* use, so you can test with no server online
and no player connected. Older events are pruned every hour.

## The builder is a test bench

The builder (`/rules/new`, or **Edit** on a rule) writes the rule as a
sentence — **When · If · Then · Protections · Details** — and tests it while
you type.

**Conditions come in groups.** **+ Condition** adds to a group, **+ Group**
starts another. Each group says whether *all*, *any*, *not all* or *none* of
its conditions must hold, and the rule says whether *all of*, *any of*, *not
all of* or *none of* **these groups** must hold — so *"VIP and level 50, or
clan tag 7DV"* is two groups joined by *any of*. With a single group, it is
the old *all / any* list. **see as an expression** shows the same logic as
text. See
[How conditions combine](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview#how-conditions-combine).

**Recent runs** — a strip of the last times the rule's trigger happened (up to
48), each cell coloured by what happened: simulated run, fired, did not match,
on hold, exempt, error, not running. **Click a cell to overlay it** on the
builder: every condition shows the value it read and whether it passed, every
group whether it matched, and the ladder shows the rung that ran. **Run again
with the edits** answers *would it fire now?* for that same event.

## The 7-day replay

Before you publish, the builder replays the rule **as typed** over the last
week of real events, next to the published version:

- **Would fire** N times, and **+/−N vs the current version**
- the players it would reach, and how many of them are VIP
- how many times each step of the ladder would run
- **Who changed fate with the edits** — players who now fire, no longer fire,
  or are now exempt

Limits and the escalation ladder are replayed too, with a history of their
own, so a cooldown or a daily cap counts as it would have. The replay reads
at most the newest 2,000 events of the trigger across the servers in scope,
and says since when it covers when that is less than the week.

## Try it

At the bottom of the builder. It judges the rule **as typed**, unsaved
edits included, against either a **saved event** or a **connected player**.

- Edit the event's fields to ask *"and what if he had used a knife?"*.
- The verdict follows your typing: every check the engine makes, each
  condition's actual value against the expected one, and the actions that
  would run with their messages rendered.

Nothing is ever sent to the game from here.

## The event simulator

![Event simulator](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/simulate.png)

**Rules → Simulator** (`/rules/simulate`). **Build from scratch** or **Use a
recent real event** — the kind of event, the server, the player, the target,
the weapon, the chat message — then **Simulate this event**. You see **every
enabled rule of the server** that listens, in the order the engine runs them:
which would fire and which would not (with its conditions), the ladder step,
the cooldown, and whether it *would only record* (simulation) or *would really
send*.

It also flags **conflicts** between rules that would fire together:

| Conflict | Meaning |
| --- | --- |
| Double punishment | More than one rule punishes, kicks or bans the same player for the same event |
| Message then removed | One rule messages the player while another kicks or bans them, so the message is likely never read |

**Saved tests.** **Save as a test** keeps the event under a name (up to 120
characters). The server's newest 20 are listed under **Saved tests**; click
one to run it again against the rules as they are now — handy after editing
a rule. A test stores the event, not an expected result.

Nothing is recorded or sent — not to the game, not to Discord.

## Why didn't it fire?

A tab on the rule's page. Pick a player and a window — **Last hour**,
**Today**, or **Pick** a range (UTC) — and **Explain**. Up to 25 saved events
of the rule's trigger for that player are walked through the engine's checks,
in the engine's order:

1. the rule is enabled
2. it is not paused
3. it listens for the event's trigger
4. the player is not exempt
5. the limits allow it — cooldown, then the per-player cap
6. the conditions hold

You get *the path of the event*: the step it stopped at, with the value read
against the value expected, and **Open in the simulator** to play with it.
Limits are replayed **as they stood when the event arrived**; enabled, paused
and exempt are judged as the rule stands now. When the rule did fire, the
execution is linked instead.

## Simulation mode

The builder's state switch is **Switched off · Simulating · Live**. A
simulating rule is evaluated, rate limited and recorded in the history as
usual, with the messages it *would* have sent, but **nothing reaches the
game**. New rules are published **in simulation** (**Publish in
simulation**), and rules from recipes always start there.

In the feed and the history, simulated runs are lavender.

## Going live

![A rule ready to act](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rule.png)

A simulating rule is **ready to act** after **three whole days** of clean
runs: at least one simulated run, no failed or partly failed run since the
first one, and no health warning. Its page then says **Ready to act for
real**, with how many days and runs, and how many players it *would have*
punished or reached; until then it says **Still simulating**.

**Go live for real** shows a last checklist — ran at least 3 days in
simulation, the CRCON key can run its actions, exemptions reviewed — and can
**tell Discord when it goes live** on a channel you pick. Confirming takes the
rule out of simulation as a new version: from then on its actions reach the
game.

The rules list marks these rules *ready to act*, the Briefing suggests the
first one, and the Inbox lists them as *Ready to go live* once they have ten
runs.

In the builder, **Live** stays locked (*Live in N days*) until the three days
have passed — except for a rule that has already run for real before.

## Drafts and versions

Editing an **enabled** rule does not change what the engine runs:

- **Save draft** keeps your edits aside — *"The engine keeps running the
  published rule."* The rule shows *draft pending*, and its page shows the
  published and draft side by side.
- **Publish edits** (or **Publish** on the rule's page) makes the draft live
  right away. **Discard** throws it away.
- A draft is validated like a save, so it can always be published unless
  something changed under it.

The rule's **Versions** tab lists every version. Pick any two to see the
**differences** — the sentence and every field, before and after (*Only what
changed*) — with both replayed over the last seven days of events.
**Restore vN** loads an old version **as a draft**: nothing changes until you
publish it. Versions recorded before snapshots existed cannot be restored.

A draft or a restored version never switches a rule on or off, and never
changes a pause: only the definition travels.

## Pausing a rule

**Pause 30 minutes**, **Pause 2 hours**, or **Pause until...** a date and
time, with an optional reason (*event night, testing a new map*), from the
rules list or the rule's **More options**. The rule stays enabled; the engine
skips it until then and picks it up again by itself. **Resume now** ends the
pause early. Pauses and resumes are recorded in the rule's versions.

## Exemptions

Under **Protections** the builder lists players a rule never touches:

| Option | Matches |
| --- | --- |
| **Never VIPs** | Players who hold VIP on the server |
| **Never players with any of these flags** | CRCON profile flags — flag your staff and they are exempt |
| **Never these players** | Specific player IDs |

Exemptions are checked **before any condition**, so a kick rule cannot kick a
VIP because a condition was written a little too broadly. Engine metrics
count skips as *Exempt*.

## Permissions

| Permission | Grants |
| --- | --- |
| `view_rules` | The rule's page, *Why didn't it fire?*, the simulator |
| `manage_rules` | The builder (run strip, replay, *Try it*), saving drafts, publishing, **Go live for real**, restoring versions, pausing, saving and deleting simulator tests |

---

***

**←** [Inbox and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
