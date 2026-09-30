🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord)
***

# Discord

## Menu

- [Registering a webhook](#registering-a-webhook)
- [The delivery log](#the-delivery-log)
- [Posting from a rule](#posting-from-a-rule)
- [Ticket announcements](#ticket-announcements)
- [Delivery](#delivery)
- [Permissions](#permissions)
- [Tips](#tips)

***

Rules, tickets and the VIP shop post to Discord through **webhooks** registered once in the
app. Discord is **not a module**: it is always available, on every
server.

![Discord](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/discord.png)

## Registering a webhook

In Discord, create a webhook under *Channel → Edit → Integrations → Webhooks*
and copy its URL. Then **Settings → Discord → New webhook** (`/discord/new`):

| Field | Notes |
| --- | --- |
| Name | How rules and exported files refer to it, e.g. `Admin log` |
| Channel label | Free text, e.g. `#admin-log`. Discord only tells the app the channel's id, so this is how the list says where a webhook posts |
| Webhook URL | Only Discord's own webhook addresses are accepted. **Stored encrypted and never shown again** — leave it blank when editing to keep the current one |
| Sender name | Optional. A rule can still set its own |
| Avatar | An image URL, optional |

The webhook is **checked with Discord when it is saved**, and **Send a test**
posts a message with one click. The list shows each webhook with its channel
label, sender, **last delivery** (*ok*, or the error and since when it has
been failing) and **who uses it** — the rules, the Tickets module, the VIP
shop — so a webhook somebody deleted on Discord's side is noticed here rather
than in a silent channel.

A webhook that rules still post to cannot be removed: change the rules first.

> [!NOTE]
> Rules refer to a webhook by id and exports by name, so the URL — which lets
> anybody holding it post to the channel — never appears in a rule, an export
> or the audit trail. When a URL is rotated on Discord, replace it in one
> place. Older rules that carried a URL in their action are moved to
> registered webhooks automatically at startup.

## The delivery log

Pick a webhook and **Latest deliveries** lists what the rules sent to it over
the last 7 days: the time, *ok* or the error, and where it came from — the
rule and the player, or the chat command and who typed it. It shows the
latest 60, and how many older ones are in the window.

Messages from tickets and the VIP shop are not listed there; their outcome is
on the ticket or the order.

## Posting from a rule

The action **Send a Discord message** (group *Integrations*) is the only
action that does not call CRCON, so it needs no CRCON permission. In the
builder it opens a drawer:

| Part | Notes |
| --- | --- |
| Webhook | Required, picked from the registered ones, with its state (*verified*, *failing*, *never used yet*) and **Manage webhooks** |
| Delivery | **Edit in place** (rewrite one message instead of posting a new one), **In a thread** (a thread id, or a forum post opened by title the first time and reused after), **Aggregate** (for scheduled rules: one post for all the players of the sweep), **Silent** (no notification) |
| Card | Title, description, up to 25 fields, bar colour, thumbnail — placeholders allowed |
| Mentions | Role ids it may mention |
| More | Text outside the card, footer, sender name and avatar |

A message or a card is needed — at least one. Texts are cut to Discord's
limits instead of being refused.

The drawer **previews** the message with the latest real event, shows the
**last delivery of this action**, and can **Send a test to the channel**
(marked as a test).

Edit in place suits a live status board: the rule keeps rewriting the same
message instead of flooding the channel.

## Ticket announcements

The **Discord alert** section of the
[ticket settings](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Tickets#settings)
announces new tickets on a chosen webhook, coloured by priority, from the
priority you choose, and can mention roles. It is written in the app's
default language.

## Delivery

Posts never slow down a rule or a ticket: they are queued as background jobs
(`DeliverWebhook`).

- One post at a time, which keeps well under Discord's per-webhook rate limit.
- When Discord still answers *429*, the job waits exactly as long as Discord
  asks, without spending an attempt.
- Up to **5 attempts** for other failures.
- The outcome is written to the rule execution's deliveries (visible in the
  [history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history)),
  to the webhook's last success or error, and to its delivery log.

## Permissions

| Permission | Grants |
| --- | --- |
| `manage_integrations` | *Manage Discord integrations*: **Settings → Discord**, adding, testing and removing webhooks, the delivery log |

Picking a webhook in a rule only needs `manage_rules`.

## Tips

- Create one webhook per channel (admin log, reports, tickets) and give each a
  clear name — the name is what the rule builder and exports show.
- Use **Send a test** after rotating a URL on Discord.

---

***

**←** [Live cockpit and feed](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Live-feed) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop) **→**
