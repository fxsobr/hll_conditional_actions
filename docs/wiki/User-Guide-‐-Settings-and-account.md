🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Settings and account](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account)
***

# Settings and account

## Menu

- [The settings hub](#the-settings-hub)
- [Engine metrics](#engine-metrics)
- [My account](#my-account)
- [Permissions](#permissions)

***

**Settings**, at the bottom of the icon rail (`/settings`), is one page with
everything that is configured rather than used day to day.

![Settings](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/settings.png)

## The settings hub

Each card only shows when your role may open what it leads to. The search box
on top filters the cards (press `/`).

| Card | Shows | Leads to |
| --- | --- | --- |
| **Servers** | How many servers, and how many have the stream down; the ones with a problem first | **Manage servers** (`/servers`) — see [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server) |
| **People** | Accounts and how many have no two factor; built-in and custom roles | [Users and Roles](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor) |
| **Integrations** | Discord webhooks and how many are failing; *Payments and email* when the VIP shop is installed | [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) · [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop) |
| **Engine** | The queue, the p95 time and how many streams are up; the modules switched on | [Engine metrics](#engine-metrics) · [Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) |
| **My account** | Your role and open sessions; a warning while two factor is off | [My account](#my-account) |
| **Preferences** | Language, theme, and the time zone times are shown in | Only for you, on this browser |
| **About** | The installed version, the latest release, **Check now**, the release notes | For accounts that manage users |

## Engine metrics

![Metrics](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/metrics.png)

**Engine metrics** (`/metrics`) shows what the engine is doing, refreshed every
two seconds (**Pause** stops it):

- **Events received** per minute
- **Rules in the last hour** — fired against skipped
- **From event to action** — p50, p95 and p99, and the queue
- **Why they were skipped** — conditions did not match, on cooldown, per-player
  cap in 24 h, exempt
- **Log streaming** — reconnects in the last hour. Repeated reconnects mean a
  server the app cannot hold a stream to
- **CRCON calls** — every endpoint with its calls, errors, average time, p95,
  for all servers or one. When CRCON answers *403*, the page says which
  permission the key is missing, with a link to the runs that failed

The numbers are kept in memory for the last hour: they start again when the
application restarts, and **Reset counters** clears them.

## My account

`/account`, from the avatar menu or the Settings hub.

**Sessions.** Each browser you signed in from is a session, with its device,
address and when it was last seen. **End** signs one out; **End the other
sessions** signs out every one but this.

**Password.** Changing it asks for the **current password**. The new one needs
**12 to 72 characters, mixing letters and numbers**, and cannot be `admin`,
`password`, `senha` or your username. Saving signs out your other sessions.

**Two factor**, in three steps:

1. **Scan in the app** — Google Authenticator, 1Password, Aegis or any TOTP
   app. No camera? Type the key shown.
2. **Confirm a code** — the six digits the app shows now.
3. **Save the codes** — ten recovery codes, each good once. Download or copy
   them, tick *I saved them somewhere safe*, then **Turn 2FA on**.

Nothing changes until the last step. Once it is on, the page shows how many
recovery codes are left; **New recovery codes** and **Turn off** ask for a
code from the app first (a recovery code works too).

More on how two factor, sessions and password resets work:
[Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor).

## Permissions

| Permission | Grants |
| --- | --- |
| everyone | The hub, **My account**, **Preferences** |
| `view_servers` / `manage_servers` | The Servers card / adding servers and **Modules** |
| `manage_users` | Users, and **About** |
| `manage_roles` | Roles |
| `manage_integrations` | Discord, and the VIP shop's payments and e-mail |
| `view_executions` | Engine metrics |

---

***

**←** [Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide)
