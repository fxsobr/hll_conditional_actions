🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / Rules / [Actions](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions)
***

# Rules ‐ Then (actions)

## Menu

- [How actions run](#how-actions-run)
- [Placeholders](#placeholders)
- [Talking to players](#talking-to-players)
- [Punishing](#punishing)
- [Moving between teams](#moving-between-teams)
- [Marking and rewarding](#marking-and-rewarding)
- [Integrations](#integrations)
- [Every action and the CRCON permission it needs](#every-action-and-the-crcon-permission-it-needs)

***

## How actions run

Actions run **in order, top to bottom**, and each one is recorded separately in
the rule's history with what CRCON answered.

- One action failing does **not** stop the ones after it. A message that could
  not be delivered because the player already left will not prevent the
  Discord post.
- Turn on **Escalate repeat offenders** and the list stops being a list and
  becomes a ladder: one step per offence. See
  [Overview → Escalation](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Overview#escalation).
- In **simulation**, everything is evaluated and recorded — including the exact
  message text — and nothing is sent.

Every action except the Discord one needs a CRCON permission. If the server's
key does not hold it, the rule shows **"This will never work"** and names the
missing permission before it ever runs.

## Placeholders

Any text field marked as a template accepts placeholders in `{braces}`. The
builder lists them under the field; click one to insert it.

```
Welcome {player_name}! You are level {player_level} on {server_name}.
```

| | | |
| --- | --- | --- |
| `{player_name}` | `{player_id}` | `{player_level}` |
| `{player_role}` | `{team}` | `{unit_name}` |
| `{clan_tag}` | `{is_vip}` | `{playtime_minutes}` |
| `{kills}` | `{deaths}` | `{teamkills}` |
| `{combat}` | `{offense}` | `{defense}` |
| `{support}` | `{map_name}` | `{game_mode}` |
| `{server_name}` | `{server_player_count}` | `{weapon}` |
| `{target_player_name}` | `{message}` | |

`{weapon}`, `{target_player_name}` and `{message}` only carry a value on the
triggers that produce them. A placeholder with nothing behind it is left
empty rather than printing the braces.

---

## Talking to players

### Message the player

Sends a private in-game message to the player the rule fired for.

- **Message** — required, accepts placeholders.

```
Message: Welcome {player_name}! Rules: no team killing, use a mic in squads.
```

Needs `can_message_players`.

### Message every player

The same message to everybody connected, one message each.

- **Message** — required, accepts placeholders.

Placeholders about *a* player make little sense here; keep it to
`{server_name}`, `{map_name}` and the like.

Needs `can_message_players`.

### Set the broadcast

Replaces the server's scrolling broadcast message. It **stays** until
something changes it again.

- **Message** — required, accepts placeholders.

Needs `can_change_broadcast_message`.

> [!WARNING]
> This overwrites whatever the broadcast said before, including a broadcast
> CRCON's own auto-broadcast is managing. If you use CRCON's rotation, prefer
> **Broadcast temporarily**.

### Broadcast temporarily

Sets the broadcast, then **puts the previous one back** after the duration.

- **Message** — required, accepts placeholders.
- **Duration (seconds)** — required, minimum 5.

```
Message:  {player_name} just topped the scoreboard!
Duration: 30
```

The restore is queued as a background job with retries, so a hiccup in the
game server does not leave your announcement up forever.

Needs `can_change_broadcast_message`.

### Set the welcome screen

Replaces the text new players see when they join.

- **Message** — required, accepts placeholders.

Needs `can_change_welcome_message`.

---

## Punishing

### Punish the player

Kills the player where they stand. The mildest real consequence — it
interrupts what they are doing and shows them the reason.

- **Reason** — required, shown to the player, accepts placeholders.

```
Reason: Team killing on {map_name}. The next one is a kick.
```

Needs `can_punish_players`.

### Kick the player

Removes them from the server. They can come straight back.

- **Reason** — required, shown to them.

Needs `can_kick_players`.

### Temporarily ban the player

- **Reason** — required.
- **Duration (hours)** — required.

```
Reason:   Repeated team killing
Duration: 2
```

Needs `can_temp_ban_players`.

### Permanently ban the player

- **Reason** — required.

Needs `can_perma_ban_players`. Consider **Add to a blacklist** instead — a
blacklist entry carries the reason, the author and an expiry, and is easier to
review later.

### Add to a blacklist

Adds a CRCON blacklist record, which is the reviewable version of a ban.

- **Blacklist** — required. The numeric id of the blacklist in CRCON; `0` is
  the default one.
- **Reason** — required, accepts placeholders.
- **Duration (hours)** — optional. Leave at `0` for permanent.

Needs `can_add_blacklist_records`.

---

## Moving between teams

### Switch the player's team now

Moves them immediately, mid-fight.

Needs `can_switch_players_immediately`.

### Switch the player's team on death

Queues the switch; it happens the next time they die. Much less disruptive,
and the right one for balancing.

Needs `can_switch_players_on_death`.

---

## Marking and rewarding

### Add a flag

Puts a CRCON flag on the player. Flags are visible to every admin in CRCON and
can be read back by other rules with `Flags` **contains**.

- **Flag** — required. An emoji or short text.
- **Comment** — optional, accepts placeholders.

```
Flag:    👀
Comment: Auto-flagged: {teamkills} team kills on {map_name}
```

Needs `can_flag_player`.

### Remove a flag

- **Flag** — required, the one to remove.

Needs `can_unflag_player`.

### Add to the watchlist

Puts the player on CRCON's watchlist, which announces them to admins on their
next connect.

- **Reason** — required, accepts placeholders.

Needs `can_add_player_watch`.

### Remove from the watchlist

No parameters. Needs `can_remove_player_watch`.

### Grant VIP

- **Description** — required, the note that appears beside the VIP entry.
- **Duration (hours)** — optional. `0` or empty means no expiry.

```
Description: Seeding reward {map_name}
Duration:    24
```

Needs `can_add_vip`.

### Remove VIP

No parameters. Needs `can_remove_vip`.

---

## Integrations

### Send a Discord message

Posts to a Discord webhook. The only action that does not touch CRCON, and so
the only one that needs no CRCON permission.

- **Webhook URL** — required.
- **Message** — required, accepts placeholders.

```
Message: 🚨 {player_name} ({player_id}) — {teamkills} team kills on {map_name}
```

Delivery is queued as a background job with retries and backoff, so a Discord
outage does not slow the rule down or lose the message.

> [!NOTE]
> Create a webhook in Discord under *Channel → Edit → Integrations →
> Webhooks*. Anybody holding that URL can post to the channel, so treat it as
> a secret.

---

## Every action and the CRCON permission it needs

| Action | CRCON permission |
| --- | --- |
| Message the player | `can_message_players` |
| Message every player | `can_message_players` |
| Set the broadcast | `can_change_broadcast_message` |
| Broadcast temporarily | `can_change_broadcast_message` |
| Set the welcome screen | `can_change_welcome_message` |
| Punish the player | `can_punish_players` |
| Kick the player | `can_kick_players` |
| Temporarily ban the player | `can_temp_ban_players` |
| Permanently ban the player | `can_perma_ban_players` |
| Add to a blacklist | `can_add_blacklist_records` |
| Switch the player's team now | `can_switch_players_immediately` |
| Switch the player's team on death | `can_switch_players_on_death` |
| Add a flag | `can_flag_player` |
| Remove a flag | `can_unflag_player` |
| Add to the watchlist | `can_add_player_watch` |
| Remove from the watchlist | `can_remove_player_watch` |
| Grant VIP | `can_add_vip` |
| Remove VIP | `can_remove_vip` |
| Send a Discord message | *none — it does not call CRCON* |

Grant only what your rules use. The connection test lists what the key holds,
and a key belonging to a CRCON superuser is refused outright.
