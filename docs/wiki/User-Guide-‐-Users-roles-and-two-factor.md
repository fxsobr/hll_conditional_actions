🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor)
***

# Users, roles and two factor

## Menu

- [Permissions](#permissions)
- [Roles](#roles)
- [Server scope](#server-scope)
- [Users](#users)
- [Two factor](#two-factor)
- [Sessions and passwords](#sessions-and-passwords)
- [Forgotten password](#forgotten-password)

***

Access is role based. A user has one role, a role carries a list of
permissions, and the user's server list says where they apply. Both pages are
under **Settings → People**.

## Permissions

| Permission | Label | Grants |
| --- | --- | --- |
| `view_servers` / `manage_servers` | View servers / Add, edit and remove servers | The servers and the cockpit / the address, API key, stream, and **Modules** |
| `view_rules` / `manage_rules` | View rules / Create, edit and remove rules | Rules, the simulator / creating, simulating, publishing, restoring versions |
| `view_executions` | View the rule history | History, the Inbox, engine metrics — what each rule did, and why it did not |
| `view_live_feed` | Watch the live event feed | The servers' events in real time |
| `view_stats` | See matches, players and leaderboards | Scoreboard, squads, match history, Players |
| `view_progression` / `manage_progression` | See seasons and achievements / Run seasons and edit achievements | Seasons, achievements |
| `view_tickets` / `manage_tickets` | See player tickets / Answer and close player tickets | Answering, assigning, closing, internal notes, ticket settings |
| `manage_players` | **Act on players** | Message, punish, kick, ban, watchlist and VIP, from the player pages and from tickets |
| `manage_integrations` | Manage Discord integrations | Discord webhooks, and the VIP shop admin |
| `manage_users` | Manage users | Creating accounts, limiting servers, switching two factor off |
| `manage_roles` | Manage roles and permissions | The Roles page |

- A `manage_*` permission includes the matching `view_*`, and
  `manage_users` includes `manage_roles`. The Roles page shows these as
  *included*.
- `manage_players` stands alone: answering tickets does not by itself let
  somebody kick. The v0.3.0 upgrade gave it to **every role that had
  `manage_tickets`**, built-in or custom, so nobody lost what they could do.

Every page is enforced server side, and every change re-checks the permission.
Hiding a button is presentation, not authorization.

## Roles

![Roles](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/roles.png)

Three roles are built in:

| Role | Can |
| --- | --- |
| **Administrator** | Everything |
| **Operator** | Write rules and watch what they do, answer tickets and act on players, run seasons — but not touch server credentials, Discord or user access |
| **Viewer** | Read only |

**Built-in roles are read-only.** To change one, **Duplicate** it — the copy
is named *(copy)* — and edit the copy. A custom role can be deleted once
nobody holds it (*Move its users to another role first.*).

## Server scope

The role says *what* an account may do; its server list says *where*. An
account set to **All, including the ones added later** reaches every server,
which is what a single-community install wants.

Pick servers and the account is confined to them: it sees only those servers,
their rules, history, tickets and players. Fleet-wide rules that reach one of
its servers are visible but read only, since changing one would affect servers
it does not administer. Acting on players also needs the player's server to
be one of the account's.

## Users

`/users` lists every account with its e-mail, role, servers (*All* when none
are picked), two factor (*on*, *setting up* or *off*), last sign in and an
**Active** switch. A banner names the accounts that sign in without two factor
— *this tool can kick and ban*.

Clicking a row opens the account:

- username, full name, e-mail
- a first or temporary password, and **Ask for a new password at the next
  sign in**
- the role (with *What each role can do*)
- **Servers this account reaches**
- **Switch 2FA off**, when it is on
- **Deactivate account**, **Remove user**

Deactivating an account signs it out everywhere. You cannot deactivate or
remove yourself, and the last account that can manage users cannot be
deactivated.

## Two factor

Optional, per account, set up in three steps from
[My account](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account#my-account).
TOTP only — an authenticator app, no SMS.

- The secret is encrypted at rest, and nothing is stored until a code proves
  the app is reading it.
- Ten single-use recovery codes, stored only as hashes.
- A code is accepted once; ten wrong codes in fifteen minutes and the account
  stops being answered for a while.
- The code step of the sign in expires after five minutes.

**Locked out** — the phone and the codes are both gone: anybody who can manage
users opens the account on **Users** and uses **Switch 2FA off**. Keep a
second administrator account for exactly this.

## Sessions and passwords

- Every browser you sign in from is a **session**. **My account** lists them,
  and ends one or all the others.
- Changing your password needs the **current password**, and a new one of
  **at least 12 characters with letters and numbers**. It signs out your
  other sessions.
- A deactivated account, or a password reset, signs out every session of that
  account.

## Forgotten password

**Forgot** on the sign in page (`/login`) asks for your e-mail and sends a
link to choose a new password.

- The link lasts **30 minutes** and works once.
- The page always says *Check your e-mail*, whether or not the address has an
  account, so it cannot be used to find out who has one.
- Three requests per address every 15 minutes.
- The new password follows the same rules, and every session of the account
  is signed out. Two factor is left as it was.

> [!IMPORTANT]
> The e-mail goes through the **VIP shop's mail settings**
> (**Community → VIP shop → E-mail**), the only mail server the app has.
> Without them the page says so, and an administrator resets the password
> from **Users** instead — typing a temporary one and ticking *Ask for a new
> password at the next sign in*.

---

***

**←** [Rules · Then](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions) · **↑** [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) · [Settings and account](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Settings-and-account) **→**
