🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [The interface](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-The-interface)
***

# The interface

## Menu

- [The areas](#the-areas)
- [The header](#the-header)
- [The server scope](#the-server-scope)
- [Search: Ctrl K](#search-ctrl-k)
- [Notifications](#notifications)
- [Theme and language](#theme-and-language)
- [Phones and tablets](#phones-and-tablets)
- [Briefing, the home page](#briefing-the-home-page)

***

Since v0.3.0 every page answers one question — *what needs me?*, *what is
happening?*, *is this rule working?* — and the server is a filter you pick in
the header rather than a place you navigate to.

![Briefing](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/briefing.png)

## The areas

The **icon rail** on the left (wide screens) holds the areas, top to bottom:

| Area | Opens | What it is for |
| --- | --- | --- |
| **Briefing** | `/` | What needs you, and how the servers and rules are doing. [Below](#briefing-the-home-page) |
| **Live** | `/servers/:id` | The match on the server in scope: score, feed, best players. [Live](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) |
| **Rules** | `/rules` | Rules, History and the Simulator. [Rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules) |
| **Inbox** | `/inbox` | Attention items and player tickets in one list. [Inbox](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) · [Tickets](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets) |
| **Community** | Seasons | Seasons, Achievements, Matches and the VIP shop |
| **Players** | `/players` | Everyone the servers have seen. [Players](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Players) |
| **Modules** | `/servers/:id/marketplace` | What each server runs. [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) |
| **Settings** | `/settings` | Servers, people, Discord, metrics, your account. [Settings](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account) |

An area you have no permission for, or whose module no server of yours runs,
is not shown. **Inbox** carries a badge with what is open: attention items
plus open tickets (a ticket that waited too long counts once).

Your avatar sits at the bottom of the rail. Its menu has **My account**,
**Theme**, **Language**, **About** (the version and the release notes, for
accounts that manage users) and **Sign out**.

## The header

- The page **title**, and beside it the area's pages as **tabs** — for
  example *Rules · History · Simulator*, or *Seasons · Achievements ·
  Matches · VIP shop*.
- The **search** field (see [Ctrl K](#search-ctrl-k)).
- The **scope** pill (see below).
- The **bell** (see [Notifications](#notifications)).
- The page's own buttons, such as **New rule**.

On a wide screen, when a page shows tabs, the search field and the bell step
aside to make room. Ctrl K still works.

## The server scope

The pill in the header says which server you are looking at — its name and
whether its log stream is up — or **All servers** with how many you have.

- Picking a server **keeps your page**: from BR #1's leaderboard to BR #2's
  leaderboard, from a server's rules to the other server's rules.
- **All servers** goes back to the Briefing.
- The scope lives in the address (`/servers/2/rules`), so a link you share
  opens on the same server.
- The pill shows in Live, Rules, Inbox and Community. Settings, your account
  and the VIP shop admin have no scope.

## Search: Ctrl K

**Ctrl K** (**Cmd K** on a Mac), or a click on *Search players, rules,
matches…*, opens one search across:

![Ctrl K](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/search.png)


| Group | Finds |
| --- | --- |
| Players | By name or ID |
| Rules | Rules that mention what you typed |
| Tickets | By player or number |
| Matches | CRCON's recent matches, from 3 characters on |
| Actions | For the best player found: **Ban**, **Message**, **Open the feed** |
| Pages | Go to a page, or run a command: *New rule*, *Add a server*… |

Up to five results per group. **↑ ↓** move, **Enter** opens, **Tab** jumps to
the result's actions, **Esc** closes. With the box empty it lists the pages
you can go to.

## Notifications

The **bell** collects, for you:

- open attention items — a stream down, a rule failing, a player to review, a
  rule ready to go live, a VIP purchase not delivered, a ticket waiting
- tickets opened in the last 24 hours
- internal notes that mention you as `@username` or `@firstname`, in the last
  7 days

A dot on the bell means something is unread. Opening an item marks it read;
**Mark all as read** clears the lot. Read marks are yours alone — another
admin still sees the item as new. **Everything / Mentions** narrow the list,
and **See everything in the Inbox** opens the Inbox.

## Theme and language

- **Theme** — *Dark*, *Light* or *System* (follow the device). Remembered by
  this browser.
- **Language** — Português, Español, English. Remembered for the session.

Both are also in **Settings → Preferences**.

## Phones and tablets

Below 1280 px wide the rail becomes a **floating tab bar** at the bottom:

<img src="https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/phone.png" alt="The Briefing on a phone" width="320">


| Screen | Tabs |
| --- | --- |
| Tablet | Briefing, Live, Rules, Inbox, Community, Players |
| Phone | Briefing, Live, Rules, Inbox, **More** |

**More** opens a sheet with the other areas (Community, Players, Modules,
Settings), today's VIP shop purchases, the **server in scope** (this is the
phone's scope switcher), the theme, and **Sign out**. The version is at the
bottom of the sheet.

## Briefing, the home page

The Briefing (`/`) answers *what needs me?* for every server you may see. It
refreshes every 10 seconds.

- **A greeting** with how many times your rules acted this week, compared with
  the week before.
- **Five numbers**, each a link: *Active rules* (and how many are in
  simulation), *Playing now*, *Success* (the week's success rate),
  *Attention* (how many are urgent) and *Tickets* (how many are unassigned).
- **Ready to act** — a rule that has been clean in simulation long enough,
  with what it would have done: **Review and activate** opens the rule, and
  *See the N simulations* opens its simulated runs in the History. See
  [Testing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Testing-rules#going-live).
- **Rule fires** over 7, 30 or 90 days — all, live only or simulation only —
  with fires, players reached, failures and the average time.
- **Needs you** — the top items of the Inbox, with **Open the inbox**.
- **Servers now** — each server's live score and population.

A fresh install, or a new server with nothing set up yet, gets a list of first
steps instead. **Skip for now** hides it.

Each part only shows what your role may see: without `view_executions` there
are no fires and no attention items, without `view_tickets` no tickets.

---

***

**←** [Connecting a CRCON server](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Writing rules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules) **→**
