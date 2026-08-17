🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) / [Requirements](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements)
***

# Requirements

## Menu

- [On this side](#on-this-side)
- [On the CRCON side](#on-the-crcon-side)

***

## On this side

- **Docker** and **Docker Compose**. Nothing else: the stack builds and
  runs Elixir, PostgreSQL and Caddy for you.
- One free port for the app to answer on. **4000** by default.
- Developing without Docker instead? See
  [Development environment](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment).

**Running on the same machine as CRCON is the normal setup.** Each stack keeps
its own database, on its own Docker network and unpublished, so they cannot
collide; CRCON answers on 8010 and 9010 while this app answers on 4000,
leaving 80 and 443 alone entirely.

## On the CRCON side


1. A CRCON user with an **API key** (Django admin → *Django API Keys*).
2. That user needs the `can_view_structured_logs` permission, plus whatever the
   actions your rules use require (`can_message_players`, `can_punish_players`,
   `can_kick_players`, `can_temp_ban_players`, ...).
3. **The log stream turned on**, in CRCON under
   *Settings → Others → Log Stream*, with `enabled` set to `true`. It ships
   disabled, and without it CRCON accepts the WebSocket connection and then
   immediately refuses to send anything — the server shows up as *Error* on the
   dashboard with that explanation.

Creating a dedicated user for this app is recommended: CRCON records the API
key's owner as the author of every action, so its work shows up clearly in the
CRCON audit log.

---

***

**←** [What it does](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-What-it-does) · **↑** [Getting Started](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started) · [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation) **→**
