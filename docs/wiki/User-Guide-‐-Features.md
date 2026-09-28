🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
***

# Features

## Menu

- [The marketplace](#the-marketplace)
- [Installing and removing a module](#installing-and-removing-a-module)
- [The modules](#the-modules)
- [Always there](#always-there)
- [Permissions](#permissions)

***

Rules are only part of what the app does. Tickets, achievements, seasons,
leaderboards and the live feed are **modules**, and each server picks the ones
it wants from its own marketplace.

## The marketplace

**Servers → (a server) → Marketplace**, or `/servers/:id/marketplace`.

![Marketplace](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/marketplace.png)

Every module shows as a card with what it adds, an **Installed** or
**Available** badge, and a button to install or remove it.

- **A new server starts empty.** Only the core is there: the server itself,
  its log stream and the overview. Install what that server needs.
- **Servers from before v0.2.0 got every module.** The upgrade installed all
  of them on every server that already existed, so nothing was taken away.
- Installations are **per server**. A community with three servers can run
  tickets on one and seasons on all three.

## Installing and removing a module

**Install** takes effect at once: the module's pages show up in the sidebar,
and the server's background processes restart with the new set (the ticket
listener, for example, only runs on a server with Tickets installed).

**Remove** hides the module's pages and stops its background work, but
**keeps its data**. Install it again and everything comes back as it was —
tickets, achievements, unlocks, seasons.

A page of a module that is not installed cannot be reached by an old bookmark
or a typed URL either: you land on the server's marketplace with a note saying
which module is missing. Pages that span every server (`/tickets`, `/feed`…)
open when at least one of your servers has the module.

## The modules

In the order the marketplace shows them:

| Module | What it adds | Guide |
| --- | --- | --- |
| **Conditional rules** | Rules, the rule history, the event simulator | [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) · [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules) |
| **Tickets** | Players call an admin from the game chat, admins answer from the web | [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) |
| **Achievements and seasons** | Goals players reach by playing, ranked seasons with VIP rewards | [Achievements and seasons](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Achievements-and-seasons) |
| **Leaderboard and matches** | The live leaderboard of players and squads, and every past match | [Leaderboard and matches](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Leaderboard-and-matches) |
| **Live feed** | Kills, chat and connections as they happen | [Live feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) |

## Always there

These are not marketplace modules and need no install:

| Feature | Guide |
| --- | --- |
| Discord webhooks | [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) |
| Attention inbox, metrics and the overview | [Attention and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) |

## Permissions

Installing and removing modules needs **`manage_servers`** (*Add, edit and
remove servers*), and the user must be allowed on that server. Using a module
is governed by its own permissions, listed on each page.

---

***

**↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) **→**
