🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server)
***

# Connecting a CRCON server

**Settings → Servers → Manage servers → Add server** (`/servers/new`), or
**Add a server** in the header's scope menu.

| Field | Notes |
| --- | --- |
| Name | How the server appears throughout the UI |
| Game | `Hell Let Loose` or `Hell Let Loose: Vietnam` — decides the available roles, teams and game modes |
| Time zone | The community's IANA zone. Time-of-day conditions use it, so "after 22:00" means your players' evening |
| CRCON address | The base URL, e.g. `https://rcon.example.com` |
| API key | Stored encrypted (AES-GCM) and never shown again — the form only shows how it ends |
| Notes | Only the staff sees them |
| Consume the live log stream | Turn off for a server you only want to act on with periodic rules |
| Enabled | When editing. A disabled server is ignored by the engine |

Any number of servers can be registered, of either game, mixed freely.

## The connection test is mandatory

**Save stays disabled until Test connection passes.** The test connects and
times the answer, reads CRCON's version, and calls
`get_own_user_permissions`, which needs authentication, so reaching it proves
the key is real — and its answer is checked against least privilege. It then
opens the **log stream** for a few seconds and says whether it answered and
how many events arrived, so a stream switched off in CRCON is caught here
rather than after saving.

The key is refused when it:

- belongs to a **CRCON superuser** (superusers bypass every permission check,
  so the reported permission list means nothing)
- holds **any permission this app never calls** — the review names them so you
  can remove them
- is **missing `can_view_structured_logs`**, without which no event-triggered
  rule can ever fire

The result lists the key's permissions, what is **missing** and what is
**extra**. Missing *action* permissions are only a warning: the review lists
which rule actions would fail, and you can grant them later. The VIP shop
module has permissions of its own (`can_add_vip`, `can_view_vip_ids`,
`can_view_player_history`); the review says when they are missing.

The reasoning is blunt: an API key is full control of a game server. If the key
stored here can also change server settings or manage admins, then a bug in
this app — or a leaked database — inherits all of it. Create a CRCON user for
this app alone and grant it only what the form lists.

Editing the URL or the key clears the approval (**Test again**), so the thing
that was verified is always the thing that gets saved.

## The servers list

`/servers` lists every server with its game, CRCON address, log stream state,
modules and time zone. The row menu has **Edit**, **Modules**,
**Disable** / **Enable** and **Remove** — which removes the server along with
its rules and history, after asking.

---

***

**↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface) **→**
