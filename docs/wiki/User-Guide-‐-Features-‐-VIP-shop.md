🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [VIP shop](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop)
***

# VIP shop

## Menu

- [Turning it on](#turning-it-on)
- [Opening the shop](#opening-the-shop)
- [Overview](#overview)
- [Packages](#packages)
- [Purchases](#purchases)
- [Coupons](#coupons)
- [Storefront](#storefront)
- [Customer sign in](#customer-sign-in)
- [E-mail](#e-mail)
- [Purchase rules](#purchase-rules)
- [What players see](#what-players-see)
- [How the VIP is delivered](#how-the-vip-is-delivered)
- [Permissions](#permissions)

***

A public page where players buy VIP for your servers, and the admin behind it.
Payments go through **Stripe**, **Dodo Payments** or **Mercado Pago** — how to
set each one up is in
[VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments).

![VIP shop admin](https://raw.githubusercontent.com/fxsobr/hll_conditional_actions/main/docs/screenshots/vip-shop.png)

## Turning it on

1. Install **VIP shop** from a server's
   [Modules](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features)
   page. The Modules card warns when the server's CRCON key lacks a
   permission the shop needs: `can_add_vip`, `can_view_vip_ids` and
   `can_view_player_history`.
2. Open **Community → VIP shop** (`/vip-shop`).

The public shop (`/shop`) answers only while at least one server has the
module installed and the shop is not closed; otherwise it is a *not found*
page.

## Opening the shop

Until the shop is set up, an **Open the shop** tab leads the way with a
counter (*N/5*):

1. Create the first package
2. Turn on a payment method
3. How the customer signs in
4. Receipt e-mail
5. A test purchase

The admin's tabs are **Overview**, **Packages**, **Purchases**, **Coupons**,
**Storefront**, **Payments**, **Customer sign in**, **E-mail** and
**Purchase rules**.

## Overview

Revenue in 30 days, paid orders (and how many were gifts), active VIPs from
the shop and deliveries pending; then the packages on sale, each payment
provider's state (*Production*, *In test*, *Off*), the active coupons and
the latest purchases as they arrive.

## Packages

| Field | Notes |
| --- | --- |
| Name, description | Up to 80 and 240 characters |
| Price | Above zero, in the shop's currency. A package keeps the currency it was created with |
| "Was" price | Optional, shown crossed out |
| Duration | 1 to 3,650 days; empty means permanent |
| Servers where the VIP counts | At least one |
| Featured | With a badge text, *Most chosen* by default |
| Active, order | Drag to reorder |

A preview shows the card as the customer will see it. **Duplicate** makes an
off-sale copy; **Archive package** takes it off sale while past orders keep
their details.

## Purchases

Every order, filtered by *Delivery pending*, *Paid*, *Waiting*, *Failed*,
*Refunded*, provider, period (7, 30, 90 days or all time) or a search.

Each order shows its **timeline** and the **delivery per server**:

- **Try again**, or **Try (server) now** for one server — queue the delivery again
- **Resend e-mail** — the receipt
- **Refund** — marks the order refunded and **removes the VIP** from every
  server. The money itself is returned at the provider.

**Grant manually** gives VIP without a payment: pick the player (the drawer
shows their current VIP), a duration, the servers and a reason kept in the
history, and optionally a message the player reads in game when they join. It
is recorded as a free order in your name and delivered like any other.

## Coupons

| Field | Notes |
| --- | --- |
| Code | 3 to 32 characters: letters, digits, `_` and `-`. **Generate** makes one up |
| Note | Only the team sees it |
| Type and value | *Percentage* (up to 100) or *Fixed amount* |
| Valid from, until | Optional |
| Maximum uses, once per customer | Optional |
| Good for | Tick packages; none ticked means every package |

Filter by *In force*, *Used up*, *Expired*. The page shows the discount given
and the best selling coupon.

## Storefront

How the public page looks. Changes stay a draft, previewed as *Computer* or
*Phone*, until **Publish storefront**.

- **Theme** — *Tactical*, *Crimson*, *Midnight*, *Desert* or *Arctic* — and an
  accent colour
- **Logo** and **banner** — PNG, JPG or WebP up to 2 MB
- **Top of the page** — *Cover*, *Split* or *Minimal*, the main button's text,
  military style headings
- **Page sections** — Benefits, Packages, Servers, FAQ, Final call: reorder,
  rename or switch off (Packages always shows)
- **Sign in and sign up screens** — the image's side and the texts
- **Names and texts** — shop name, subtitle, welcome and footer texts,
  whether each package lists its servers, social links

## Customer sign in

Customers have their own accounts, separate from the admin's.

- **E-mail and password** (at least 10 characters)
- **Sign in with Discord** — needs a Discord application's client ID and
  secret; the form shows the return URL to register there

At least one must be on. A customer always links the player who gets the VIP
before paying.

## E-mail

The shop's mail service: **SMTP**, **SendGrid** or **Brevo**, a sender name and
address, **Test sending**, and a template editor with a live preview.

| E-mail | Sent when |
| --- | --- |
| Welcome | A customer creates an account |
| Reset password | A customer asks for one (the link lasts 30 minutes) |
| Purchase approved | The VIP is delivered. Can be resent from Purchases |
| VIP about to end | Daily, for VIPs ending within the notice days (see below) |
| Delivery failed | A server did not confirm on the first attempt. Off by default |

Customers can turn receipts and reminders off on their account page.

> [!NOTE]
> This is the app's only mail server. **Admin password reset by e-mail**
> uses it too — see
> [Users, roles and two factor](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor#forgotten-password).

## Purchase rules

- **Currency** of new packages
- **When someone who is VIP buys again** — *Extend* (add the days to what they
  have) or *Replace* (the new package starts today)
- **Notice before it ends** — 0 to 30 days, 3 by default
- **Discord alert when a paid VIP fails** — a webhook, or *Only in the Inbox*
- **Close the shop** / **Open the shop**

## What players see

`/shop` shows the shop's hero with the servers' live status, the sections you
switched on and the package cards (*was* price, price per month, savings).

1. **Sign in** — with Discord or e-mail. **Forgot my password** sends a link.
2. **Choose a package** — the checkout goes *Player → Payment → Ready*.
3. **Who gets the VIP** — one of the customer's linked players, or **Give as
   a gift** to someone else, found by name in CRCON's player history. An
   optional message (up to 80 characters) is shown in game.
4. **Coupon**, the order summary and **Pay** — on the provider's page.
5. **The order page** follows the delivery live, server by server, and offers
   the receipt.

**My account** lists the linked players, the active VIP with **Renew**, the
orders, Discord linking, e-mail and password, and the e-mail notices. The shop
speaks Portuguese, English and Spanish.

## How the VIP is delivered

- A payment counts only when a signed webhook or the provider's API confirms
  it — never the browser alone. See
  [How a payment becomes VIP](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#how-a-payment-becomes-vip).
- The VIP is added through CRCON on **every server of the package**, with an
  end date. With *Extend*, the days are added to a VIP that has not ended
  yet; a permanent VIP stays permanent.
- Up to **5 attempts**, retrying only the servers that failed. An order ends
  *delivered*, *partial* or *failed*; the last two show in the
  [Inbox](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history)
  as *Paid VIP not granted* and, if set, on Discord.

## Permissions

| Permission | Grants |
| --- | --- |
| `manage_integrations` | The whole VIP shop admin, and the *Paid VIP not granted* items in the Inbox |

---

***

**←** [Discord](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Discord) · **↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) **→**
