🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server)
***

# Connecting a CRCON server

**Servers → Add server**

| Field | Notes |
| --- | --- |
| Name | How the server appears throughout the UI |
| Game | `Hell Let Loose` or `Hell Let Loose: Vietnam` — decides the available roles, teams and game modes |
| Time zone | The community's IANA zone. Time-of-day conditions use it, so "after 22:00" means your players' evening |
| CRCON address | The base URL, e.g. `https://rcon.example.com` |
| API key | Stored encrypted (AES-GCM) and never shown again |
| Consume the live log stream | Turn off for a server you only want to act on with periodic rules |

Any number of servers can be registered, of either game, mixed freely.

## The connection test is mandatory

**Save stays disabled until Test connection passes.** The test calls
`get_own_user_permissions`, which needs authentication, so reaching it proves
the key is real — and its answer is checked against least privilege.

The key is refused when it:

- belongs to a **CRCON superuser** (superusers bypass every permission check,
  so the reported permission list means nothing)
- holds **any permission this app never calls** — the review names them so you
  can remove them
- is **missing `can_view_structured_logs`**, without which no event-triggered
  rule can ever fire

Missing *action* permissions are only a warning: the review lists which rule
actions would fail, and you can grant them later.

The reasoning is blunt: an API key is full control of a game server. If the key
stored here can also change server settings or manage admins, then a bug in
this app — or a leaked database — inherits all of it. Create a CRCON user for
this app alone and grant it only what the form lists.

Editing the URL or the key clears the approval, so the thing that was verified
is always the thing that gets saved.

---

***

**↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Writing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules) **→**
