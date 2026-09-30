🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
***

# Features

## Menu

- [Modules](#modules)
- [Installing and removing a module](#installing-and-removing-a-module)
- [Copying from another server](#copying-from-another-server)
- [The modules](#the-modules)
- [Always there](#always-there)
- [Permissions](#permissions)

***

Rules are only part of what the app does. Tickets, achievements, seasons,
leaderboards, the live feed and the VIP shop are **modules**, and each server
picks the ones it wants.

## Modules

**Modules** in the icon rail, or `/servers/:id/marketplace`. The server in
scope is the one you are changing — pick another in the header's scope pill.

![Modules](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/marketplace.png)

Every module shows as a card with what it adds and whether it is installed.
The VIP shop's card also warns when the server's CRCON key lacks a permission
the shop needs.

- **A new server starts empty.** Only the core is there: the server itself,
  its log stream, the cockpit and the Inbox. Install what that server needs.
- **Servers from before v0.2.0 got every module.** The upgrade installed all
  of them on every server that already existed, so nothing was taken away.
- Installations are **per server**. A community with three servers can run
  tickets on one and seasons on all three.

## Installing and removing a module

**Install on this server** takes effect at once: the module's pages show up in
the icon rail and the header tabs, and the server's background processes
restart with the new set (the ticket listener, for example, only runs on a
server with Tickets installed).

**Remove** hides the module's pages and stops its background work, but
**keeps its data**. Install it again and everything comes back as it was —
tickets, achievements, unlocks, seasons.

A page of a module that is not installed cannot be reached by an old bookmark
or a typed URL either: you land on the server's Modules page with a note
saying which module is missing. Pages that span every server (`/inbox`,
`/feed`, `/vip-shop`…) open when at least one of your servers has the module.

## Copying from another server

**Copy modules from another server** installs on this server whatever the
other one runs and this one does not. It copies **which modules are
installed**, never rules, tickets or other data. Modules only this server
runs are kept, unless you tick *Also remove what (the other server) does not
run*.

## The modules

In the order the Modules page shows them:

| Module | What it adds | Guide |
| --- | --- | --- |
| **Conditional rules** | Rules, the history, the simulator | [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) · [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules) |
| **Tickets** | Players call an admin from the game chat, admins answer from the Inbox | [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) |
| **Leaderboard and matches** | The live scoreboard of players and squads, and every past match | [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) |
| **Live feed** | Kills, chat and connections as they happen, with the rules they fired | [Live](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) |
| **Achievements and seasons** | Goals players reach by playing, ranked seasons with VIP rewards | [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) |
| **VIP shop** | A public page where players buy VIP, paid with Stripe, Dodo Payments or Mercado Pago | [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop) · [Payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) |

## Always there

These are not modules and need no install:

| Feature | Guide |
| --- | --- |
| The Briefing, the cockpit, search, notifications | [The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface) |
| The Inbox and its attention items | [Inbox and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) |
| Players and the player page | [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) |
| Discord webhooks | [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) |
| Settings, engine metrics, your account | [Settings and account](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account) |

## Permissions

Installing, removing and copying modules needs **`manage_servers`** (*Add,
edit and remove servers*), and the user must be allowed on that server. Using
a module is governed by its own permissions, listed on each page.

---

***

**↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) **→**
