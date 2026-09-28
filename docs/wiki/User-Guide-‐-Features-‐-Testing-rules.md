🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules)
***

# Testing rules

## Menu

- [Saved events](#saved-events)
- [Try it, in the builder](#try-it-in-the-builder)
- [The event simulator](#the-event-simulator)
- [Why didn't it fire?](#why-didnt-it-fire)
- [Simulation mode](#simulation-mode)
- [Drafts and versions](#drafts-and-versions)
- [Pausing a rule](#pausing-a-rule)
- [Exemptions](#exemptions)
- [Permissions](#permissions)

***

Everything that lets you trust a rule that kicks or bans before it touches a
real player. All of it comes with the **Conditional rules** module.

![Rules](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/rules.png)

## Saved events

The app keeps the **latest 50 real events of each trigger on each server**.
They are what *Try it*, the simulator and *Why didn't it fire?* replay, so you
can test with no server online and no player connected.

## Try it, in the builder

At the bottom of the rule builder. It judges the rule **as typed**, unsaved
edits included, against either a saved event or a player connected right now.

- Edit the event's fields to ask *"and what if he had used a knife?"*.
- The verdict follows your typing: every check the engine makes, each
  condition's actual value against the expected one, and the actions that
  would run with their messages rendered.

Nothing is ever sent to the game from here.

## The event simulator

![Event simulator](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/simulate.png)

**Rules → Event simulator** (`/rules/simulate`). Compose a made-up event — or
start from a saved real one and edit it — and see **every enabled rule of the
server** that would answer it, in the order the engine runs them, with the
actions each would take. Rules that listen but would not fire say why.

It also flags **conflicts** between rules that would fire together:

| Conflict | Meaning |
| --- | --- |
| Double punishment | More than one rule punishes, kicks or bans the same player for the same event |
| Message then removed | One rule messages the player while another kicks or bans them, so the message is likely never read |

Nothing is recorded or sent.

## Why didn't it fire?

On a rule's page: pick a player and, optionally, a time window (UTC). Every
saved event of the rule's trigger for that player is walked through the
engine's checks, in the engine's order:

1. the rule is enabled
2. it is not paused
3. it listens for the event's trigger
4. the player is not exempt
5. the limits allow it — cooldown, then the per-player cap
6. the conditions hold

You get the step it stopped at, with the value read against the value
expected. Limits are replayed **as they stood when the event arrived**;
enabled, paused and exempt are judged as the rule stands now. When the rule
did fire, the execution is linked instead.

## Simulation mode

A switch on the rule. The rule is evaluated, rate limited and recorded in the
history as usual, with the messages it *would* have sent, but **nothing
reaches the game**. Rules from recipes start in simulation. After three days
and ten runs without a failure,
[Attention](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history)
suggests it is ready to go live.

## Drafts and versions

Editing an **enabled** rule does not change what the engine runs:

- **Save draft** keeps your edits aside — *"Draft saved. The engine keeps
  running the published rule."* The rule shows *Draft pending*.
- **Publish** makes the draft live right away. **Discard** throws it away.
- A draft is validated like a save, so it can always be published unless
  something changed under it.

Every change is recorded in the rule's **Changes**. **Restore this version**
loads an old version **as a draft** — nothing changes until you publish it.
Versions recorded before snapshots existed cannot be restored.

A draft or a restored version never switches a rule on or off, and never
changes a pause: only the definition travels.

## Pausing a rule

**Pause** from the rules list or the rule page: *Pause 30 minutes*, *Pause 2
hours*, or *Pause until…* a date and time, with an optional reason (*event
night, testing a new map*). The rule stays enabled; the engine skips it until
then and picks it up again by itself. **Resume now** ends the pause early.
Pauses and resumes are recorded in the rule's changes.

## Exemptions

The builder's **Doesn't apply to** section lists players a rule never touches:

| Option | Matches |
| --- | --- |
| **VIPs** | Players who hold VIP on the server |
| **Players with any of these flags** | CRCON profile flags — flag your staff and they are exempt |
| **These players** | Specific player IDs |

Exemptions are checked **before any condition**, so a kick rule cannot kick a
VIP because a condition was written a little too broadly. The metrics page
counts skips as *Player exempt*.

## Permissions

| Permission | Grants |
| --- | --- |
| `view_rules` | Try it, the simulator, *Why didn't it fire?* |
| `manage_rules` | Saving drafts, publishing, restoring versions, pausing, changing exemptions |

---

***

**←** [Attention and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
