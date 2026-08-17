🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / Rules / [Triggers](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers)
***

# Rules ‐ When (triggers)

## Menu

- [The eleven triggers](#the-eleven-triggers)
- [Player connects](#player-connects)
- [Player disconnects](#player-disconnects)
- [Player gets a kill](#player-gets-a-kill)
- [Player dies](#player-dies)
- [Player team kills](#player-team-kills)
- [Player writes in chat](#player-writes-in-chat)
- [Player types a chat command](#player-types-a-chat-command)
- [Player switches team](#player-switches-team)
- [Match starts](#match-starts)
- [Match ends](#match-ends)
- [On a schedule](#on-a-schedule)
- [Which fields each trigger offers](#which-fields-each-trigger-offers)

***

The trigger is what wakes the rule up. Everything else only runs after it
fires.

## The eleven triggers

| Trigger | Scope | Fires |
| --- | --- | --- |
| **Player connects** | one player | When somebody joins |
| **Player disconnects** | one player | When somebody leaves |
| **Player gets a kill** | one player | For the killer |
| **Player dies** | one player | For the victim |
| **Player team kills** | one player | For the team killer |
| **Player writes in chat** | one player | For the author |
| **Player types a chat command** | one player | For the author, when the message opens with `!`, `@` or `#` |
| **Player switches team** | one player | For the player who switched |
| **Match starts** | every player | Once per connected player |
| **Match ends** | every player | Once per connected player |
| **On a schedule** | every player | Every few seconds, per connected player |

**Scope** matters. A *one player* trigger evaluates the rule once, for the
player who caused the event. An *every player* trigger evaluates it **once per
connected player** — a 90 player server means 90 evaluations, and a rule that
messages everybody will message everybody, one at a time.

## Player connects

Somebody joined the server.

The rule does **not** run at the instant the log line arrives. It waits a few
seconds first, because the game server needs a moment before it reports the
player's level, clan tag and team — evaluating sooner would read all of those
as unavailable. The delay is `CONNECT_DELAY_MS`, 5 seconds by default; raise it
for a slow game server.

Typical uses: welcome messages, watching brand new accounts, VIP greetings.

## Player disconnects

Somebody left. Useful for logging to Discord ("the player you were watching
just left") and for cleanup — removing a temporary flag, for instance.

Note that the player is *gone*: an action that messages or punishes them will
fail. The history records the failure.

## Player gets a kill

Fires for the **killer**, once per kill. `Weapon` and `Other player` are
available.

At a busy moment this fires many times a second across the server. Anything
you attach to it should be cheap and rate limited — a **Cooldown per player**
is almost always the right companion.

## Player dies

Fires for the **victim**. `Weapon` is the weapon that killed them and
`Other player` is who killed them.

## Player team kills

Fires for the **team killer** — the one who did it. This is the trigger behind
every escalating team kill policy.

Pair it with **Escalate repeat offenders** so the first one is a warning and
the fourth is a ban. See
[Overview → Escalation](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview#escalation).

## Player writes in chat

Any chat message. Adds three fields: `Chat message` (the text), `Chat scope`
(unit / team / all) and `Chat team`.

Uses: word filters, spotting people asking for an admin, logging chat to
Discord.

## Player types a chat command

A narrower version of the above: it only fires when the message **starts with
`!`, `@` or `#`**, and it splits the message for you.

```
!discord please
│└─────┘ └────┘
│ command  command arguments
prefix
```

- `Command` is the word after the prefix, **without** the prefix — `discord`.
- `Command arguments` is everything after it — `please`.

So a `!discord` responder is: trigger *Player types a chat command*, condition
`Command` **is** `discord`, action *Message the player* with your invite link.

Use this rather than matching `Chat message` **starts with** `!discord` — the
command is already parsed, case is handled, and trailing arguments do not
break the match.

## Player switches team

Somebody moved between Allies and Axis.

## Match starts

Once per connected player, at the start of a map. Server fields such as `Map`
and `Game mode` are already the **new** ones.

Because it evaluates per player, a rule here that broadcasts once will
broadcast once *per player*. For a single message to everybody, use **Set the
broadcast** or **Message every player** with a cooldown, or accept the
duplicates.

## Match ends

Once per connected player, at the end of a map. This is where end-of-round
messages, VIP rewards for the top scorer, and Discord summaries go.

## On a schedule

Checked every few seconds against every connected player. This is the trigger
for anything that is a *state* rather than an *event*:

- a squad that has no officer **right now**
- somebody who has been in an armour squad alone for a while
- a server that has been over 90 players for the last ten minutes

Everything about the player, their squad and the server is available here.

> [!IMPORTANT]
> A scheduled rule with no cooldown will fire again on the very next check —
> every few seconds, for as long as the condition holds. Set **Cooldown per
> player**, or the player gets the same message forever.

## Which fields each trigger offers

Most fields are available everywhere. These only carry a value for the trigger
that produced them, and the builder hides them elsewhere:

| Field | Only on |
| --- | --- |
| `Chat message`, `Chat scope`, `Chat team` | Player writes in chat, Player types a chat command |
| `Command`, `Command arguments` | Player types a chat command |
| `Weapon` | Player gets a kill, Player dies, Player team kills |
| `Other player` | Player gets a kill, Player dies, Player team kills |

Everything else — the player, their squad, their profile, the server, the
clock — is available on every trigger. See
[Conditions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions).
