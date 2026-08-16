🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Security](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Security)
***

# Security

## Menu

- [The short list](#the-short-list)
- [What is throttled](#what-is-throttled)
- [Two factor](#two-factor)

***

What this app does to keep an admin panel on the open internet from
becoming somebody else's. See also
[Users, roles and two factor](User-Guide-%E2%80%90-Users-roles-and-two-factor)
for who can do what once they are in.

## The short list

- The bootstrap account is `admin` / `admin` and must change its password on
  first sign in. The login page stops offering the hint the moment it does.
- CRCON API keys are encrypted at rest and marked `redact: true`, so they do
  not reach logs or `inspect` output.
- A key belonging to a CRCON superuser is refused: the connection test asks for
  the permissions it needs and nothing more.
- The session cookie is `http_only`, `secure` and `same_site=Lax`, and expires
  after a week.
- The app sets its own CSP, referrer and permissions policies, so they hold
  even if it is served without Caddy in front.

---

## What is throttled

| Where | Limit | Catches |
| --- | --- | --- |
| Caddy, `POST /login` | 5/min per address | one machine hammering the form |
| Caddy, everything else | 300/10s per address | a flood |
| App, per address | 10/min | the same, if Caddy is not in front |
| App, per account | 20/hour | a botnet spreading guesses across addresses |

The account limit is the one that matters: it is the only one an attacker
cannot escape by renting more addresses. Both app limits are configurable —
raise the address one if your admins all sit behind a single office NAT:

```elixir
config :hll_conditional_actions, :login_rate_limit,
  ip: [limit: 30, window_ms: 60_000],
  username: [limit: 20, window_ms: 3_600_000]
```

The `rate_limit` directive needs a Caddy module that is not in the official
image, which is why `deploy/caddy/Dockerfile` builds one. To run stock Caddy,
comment that block out of the Caddyfile and point compose at `caddy:2-alpine`;
the app's own limits still apply.

## Two factor

Optional, per account, set up from **My account**. TOTP only — an
authenticator app, no email and no SMS, because this app sends neither.

- The secret is encrypted at rest, like a CRCON key, and nothing is stored
  until a code proves the app is reading it. Closing the page halfway changes
  nothing about how you sign in.
- Ten single-use recovery codes are shown once, and stored only as hashes.
- A code is accepted once. The time step it belongs to is remembered, so one
  read over a shoulder inside its 90 second window is already spent.
- Ten wrong codes in fifteen minutes and the account stops being answered.
- **The way back in** when the phone and the codes are both gone: anybody who
  can manage users has *Switch two factor off* in the row menu on **Users**.
  Keep a second administrator account for exactly this.
