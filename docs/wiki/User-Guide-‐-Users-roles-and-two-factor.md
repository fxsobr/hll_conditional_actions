🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / [Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor)
***

# Users, roles and two factor

Access is role based. A user has one role, and a role carries a list of
permissions:

| Permission | Grants |
| --- | --- |
| `view_servers` / `manage_servers` | See servers / add, edit and remove them |
| `view_rules` / `manage_rules` | See rules / create, edit and remove them |
| `view_executions` | Browse the rule history |
| `view_live_feed` | Watch the live event feed |
| `manage_users` | Manage user accounts |
| `manage_roles` | Manage roles and their permissions |

A `manage_*` permission implies the matching `view_*`.

## Server scope

The role says *what* an account may do; its server list says *where*. An
account with **no servers assigned reaches every server**, which is what a
single-community install wants and means nothing has to be configured.

Assign even one server and the account is confined to it: it sees only those
servers, their rules and their history. Fleet-wide rules that reach one of its
servers are visible but read only, since changing one would affect servers it
does not administer.

Three roles are seeded on first boot and cannot be deleted:

- **Administrator** — everything
- **Operator** — writes rules and watches what they do, but cannot touch server
  credentials or user access
- **Viewer** — read only

Every page is enforced server side through `on_mount` hooks, and every mutating
event re-checks the permission. Hiding a button in the sidebar is presentation,
not authorization.

---
