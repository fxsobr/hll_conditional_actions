🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments)
***

# VIP shop payments

## Menu

- [Which provider](#which-provider)
- [How a payment becomes VIP](#how-a-payment-becomes-vip)
- [Where to configure it](#where-to-configure-it)
- [Test first, then live](#test-first-then-live)
- [Trying webhooks on your own computer](#trying-webhooks-on-your-own-computer)
- [When a payment does not arrive](#when-a-payment-does-not-arrive)

***

The VIP shop takes money through **Stripe**, **Dodo Payments** and
**Mercado Pago**. Switch on one, two or all three: the customer picks among the
ones that are on when paying.

Step by step for each provider:

| Provider | Guide |
| --- | --- |
| Stripe | [Setting up Stripe](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Stripe) |
| Dodo Payments | [Setting up Dodo Payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Dodo-Payments) |
| Mercado Pago | [Setting up Mercado Pago](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Mercado-Pago) |

## Which provider

| | Stripe | Dodo Payments | Mercado Pago |
| --- | --- | --- | --- |
| Methods | Cards, Apple Pay, Google Pay | **Pix** and cards | **Pix**, cards and boleto |
| Taxes | Yours | Handled by Dodo (merchant of record) | Yours |
| Test and live | Decided by the key (`rk_test_` / `rk_live_`) | Separate modes, separate keys | Separate credentials |
| What the app needs | Secret key + webhook signing secret | API key + webhook signing secret | Access token (+ optional webhook secret) |
| Webhook path | `/webhooks/stripe` | `/webhooks/dodo` | `/webhooks/mercado_pago` |

For players in Brazil, Dodo Payments or Mercado Pago give them Pix. Stripe
suits players paying by card from anywhere.

## How a payment becomes VIP

1. The customer picks a package, the player who gets the VIP and a payment
   method, and the shop creates a **pending order**.
2. The app opens a checkout on the provider's side and sends the customer
   there. The order's id travels with it.
3. The customer pays on the provider's page.
4. The provider tells the app in two ways, and either one is enough:
   - a **webhook**, signed with the secret you copy from the provider;
   - the customer's browser coming back to `/shop/return/<provider>`, after
     which the app **asks the provider's API** whether the order is paid.
5. The order is marked **paid** once, however many times it is reported, and
   the VIP is granted on every server of the package in the background.

Nothing the browser says on its own marks an order paid: only a signed
webhook or the provider's API does. A declined card does not cancel the
order either — the customer can try again on the same checkout.

## Where to configure it

**VIP shop → Settings → Payments** (`/vip-shop/settings/payments`). Each
provider has a card; **Configure** opens its form:

| Field | Notes |
| --- | --- |
| Offer this payment method | Shows it to customers. It cannot be switched on until the required keys are filled |
| Mode | *Test (sandbox)* or *Live* |
| Keys | Depend on the provider. **Stored encrypted and never shown again** — leave a field blank when editing to keep what is stored |
| Webhook URL to register with the provider | The exact address to paste on the provider's side |

The webhook URL is built from the app's public address (`PHX_HOST`). If it
shows `localhost`, the provider cannot reach it — see
[Trying webhooks on your own computer](#trying-webhooks-on-your-own-computer).

## Test first, then live

1. Configure the provider in **test mode**, with test keys.
2. Make a test purchase with the provider's test card (each guide lists it).
3. Check **VIP shop → Purchases**: the order must show as paid.
4. Only then create the **live** keys and webhook on the provider's side,
   paste them, and set the mode to *Live*.

> [!WARNING]
> A test purchase of a real package grants a real VIP on the package's
> servers, even though no money moves. Use a test player, or remove the VIP
> afterwards.

## Trying webhooks on your own computer

Providers call the webhook from the internet, so a development machine needs a
public tunnel. With [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/):

```bash
cloudflared tunnel --url http://localhost:4000
```

It prints an address like `https://something-random.trycloudflare.com`.
Start the app with it, so the links the app hands out use it too:

```bash
DEV_PUBLIC_URL=https://something-random.trycloudflare.com mix phx.server
```

With Docker, export it in the shell that starts the stack:

```bash
DEV_PUBLIC_URL=https://something-random.trycloudflare.com docker compose -f compose.dev.yaml up
```

Register `https://something-random.trycloudflare.com/webhooks/<provider>` on
the provider's side. A quick tunnel gets **a new address every time it
starts**: update the webhooks on the providers when it changes.

## When a payment does not arrive

The server log says why each webhook was refused, as
`[shop] <provider> webhook refused: <reason>`:

| Reason | What to do |
| --- | --- |
| `provider disabled` | *Offer this payment method* is off for that provider |
| `bad signature` | The webhook signing secret in the app is not the one of **this** endpoint. Copy it again from the provider |
| `missing signature or webhook secret` | The secret is not filled in, or the request did not come from the provider |
| `too old` | The server clock is off by more than 5 minutes. Fix the time sync |
| `… answered HTTP 401` | The key was revoked or belongs to the other mode (test vs live) |

The provider's dashboard also lists every delivery attempt and lets you
resend one. When the webhook worked but the VIP did not, the order shows the
failing server in **VIP shop → Purchases**, with **Retry**.

***

**↑** [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) · [Stripe](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Stripe) **→**
