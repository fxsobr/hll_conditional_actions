🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord)
***

# Discord

## Menu

- [Registering a webhook](#registering-a-webhook)
- [Posting from a rule](#posting-from-a-rule)
- [Ticket announcements](#ticket-announcements)
- [Delivery](#delivery)
- [Permissions](#permissions)
- [Tips](#tips)

***

Rules and tickets post to Discord through **webhooks** registered once in the
app. Discord is **not a marketplace module**: it is always available, on every
server.

![Discord](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/discord.png)

## Registering a webhook

In Discord, create a webhook under *Channel → Edit → Integrations → Webhooks*
and copy its URL. Then **Discord → New webhook** (`/discord/new`):

| Field | Notes |
| --- | --- |
| Name | How rules and exported files refer to it, e.g. `Admin log` |
| Webhook URL | Only Discord's own webhook addresses are accepted. **Stored encrypted and never shown again** — leave it blank when editing to keep the current one |
| Sender name | Optional. A rule can still set its own |
| Sender avatar URL | Optional |

The webhook is **checked with Discord when it is saved**, and **Send a test**
posts a message with one click. The list shows each webhook's status
(*Working*, *Failing*, *Not checked with Discord yet*), its last delivery or
error, and which rules use it — so a webhook somebody deleted on Discord's side
is noticed here rather than in a silent channel.

A webhook that rules still post to cannot be removed: change the rules first.

> [!NOTE]
> Rules refer to a webhook by id and exports by name, so the URL — which lets
> anybody holding it post to the channel — never appears in a rule, an export
> or the audit trail. When a URL is rotated on Discord, replace it in one
> place. Older rules that carried a URL in their action are moved to
> registered webhooks automatically at startup.

## Posting from a rule

The action **Send a Discord message** (group *Integrations*) is the only
action that does not call CRCON, so it needs no CRCON permission.

| Parameter | Notes |
| --- | --- |
| Webhook | Required, picked from the registered ones |
| Message | Plain text, placeholders allowed |
| Embed: title, description, fields, footer | Placeholders allowed. Fields one per line as `Name \| Value` |
| Colour, thumbnail image URL, show the time | Embed look |
| Sender name, sender avatar URL | Override the webhook's |
| Roles it may mention | Role ids |
| Silent (no notification) | |
| Each time it fires | **Send** a new message, or **edit** one message |
| One message per | The key of the edited message (by default one per rule and server) |
| Thread id / forum post title | Post into a thread, or open a forum post by name the first time and reuse it after |
| One message for all the players of the sweep | For scheduled rules: one post instead of one per player |

A message or an embed is needed — at least one. Texts are cut to Discord's
limits instead of being refused.

Edit mode suits a live status board: the rule keeps rewriting the same message
instead of flooding the channel.

## Ticket announcements

The **Discord** section of the
[ticket settings](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets#settings)
announces every new ticket on a chosen webhook, coloured by priority, and can
mention roles. It is written in the app's default language.

## Delivery

Posts never slow down a rule or a ticket: they are queued as background jobs
(`DeliverWebhook`).

- One post at a time, which keeps well under Discord's per-webhook rate limit.
- When Discord still answers *429*, the job waits exactly as long as Discord
  asks, without spending an attempt.
- Up to **5 attempts** for other failures.
- The outcome is written to the rule execution's deliveries (visible in the
  [history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history))
  and to the webhook's last success or error.

## Permissions

| Permission | Grants |
| --- | --- |
| `manage_integrations` | *Manage Discord integrations*: the Discord page, adding, testing and removing webhooks |

Picking a webhook in a rule only needs `manage_rules`.

## Tips

- Create one webhook per channel (admin log, reports, tickets) and give each a
  clear name — the name is what the rule builder and exports show.
- Use **Send a test** after rotating a URL on Discord.

---

***

**←** [Live feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Attention and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) **→**
