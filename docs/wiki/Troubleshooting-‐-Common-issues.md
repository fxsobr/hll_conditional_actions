🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Troubleshooting & Help / [Common issues](https://github.com/fxsobr/hll_conditional_actions/wiki/Troubleshooting-%E2%80%90-Common-issues)
***

# Common issues

## Menu

- [Nothing happens when players connect](#nothing-happens-when-players-connect)
- ["This will never work" on a rule](#this-will-never-work-on-a-rule)
- [The connection test refuses a working key](#the-connection-test-refuses-a-working-key)
- [A rule fires but nothing reaches the game](#a-rule-fires-but-nothing-reaches-the-game)
- [Locked out of an account with two factor](#locked-out-of-an-account-with-two-factor)
- [Reporting something else](#reporting-something-else)

***

Almost everything that goes wrong is one of five things. In order of how often
it turns out to be the answer.

## Nothing happens when players connect

The log stream is not reaching the app.

1. **Overview** → does the server card say **Live**? If it says anything else,
   the WebSocket is not connected.
2. In CRCON, *Settings → Others → Log Stream*, check `enabled` is `true`. It
   ships disabled, and without it CRCON accepts the connection and then sends
   nothing.
3. Check the API key's user holds `can_view_structured_logs`.

**Metrics** shows log stream connects and disconnects. Repeated reconnects mean
a server the app cannot hold a stream to — usually a proxy in front of CRCON
closing idle WebSockets.

## "This will never work" on a rule

The CRCON key cannot do what the rule asks. The badge names the permission.
Grant it to that user in CRCON, then **Test the connection** again on the
server page so the app re-reads what the key can do.

The app only warns about servers whose key it has actually checked. A key that
was never tested is *unknown*, not broken, and gets no warning.

## The connection test refuses a working key

Two refusals are deliberate:

- **A superuser key is rejected outright.** It bypasses every permission check
  in CRCON, so a leak of this app's database would hand over the game server
  entirely. Create a regular CRCON user, give it only the permissions listed on
  the test screen, and issue a key for that.
- **Missing permissions block saving.** The test tells you which. This is the
  one place the app is deliberately strict: a key that can do more than the
  rules need is a liability with no upside.

## A rule fires but nothing reaches the game

Check whether it is in **simulation**. A simulated rule evaluates everything,
records everything, and sends nothing — the history shows the messages it
*would* have sent. The rule's badge says `Simulation` when it is on.

If it is not simulated, open the rule's **History**: each run lists what every
action did and what CRCON answered.

## Locked out of an account with two factor

- Sign in with one of the **recovery codes** shown when it was set up.
- No codes left? Any account that can manage users has **Switch two factor off**
  in the row menu on **Users**.
- Nobody left who can? See
  [Users, roles and two factor](User-Guide-%E2%80%90-Users-roles-and-two-factor).

Keep a second administrator account. It is the whole plan for this case.

---

## Reporting something else

Open an issue with:

- what you expected and what happened instead
- the rule's **Definition** tab, or its export
- the relevant lines from **History**, and from `docker compose logs app`
- your CRCON version

<https://github.com/fxsobr/hll_conditional_actions/issues>

If the problem is with CRCON itself rather than with this app, the CRCON
Discord is the better place: <https://discord.com/invite/zpSQQef>
