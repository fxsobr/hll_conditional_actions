🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) / [Stripe](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Stripe)
***

# Setting up Stripe

## Menu

- [What you need](#what-you-need)
- [1. Switch the dashboard to test mode](#1-switch-the-dashboard-to-test-mode)
- [2. Create a restricted key](#2-create-a-restricted-key)
- [3. Register the webhook](#3-register-the-webhook)
- [4. Fill in the app](#4-fill-in-the-app)
- [5. Make a test purchase](#5-make-a-test-purchase)
- [6. Going live](#6-going-live)
- [Troubleshooting](#troubleshooting)

***

The shop uses **Stripe Checkout**: the customer pays on a page hosted by
Stripe, and Stripe tells the app through a webhook.

## What you need

- A Stripe account. The dashboard may be in Portuguese; its labels are given
  below as *English (Português)*.
- The app reachable from the internet over HTTPS (for local tests, see
  [Trying webhooks on your own computer](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#trying-webhooks-on-your-own-computer)).

## 1. Switch the dashboard to test mode

Open <https://dashboard.stripe.com> and turn on **Test mode** (*Modo de
teste*) — or open a **Sandbox** (*Área restrita*). Everything created in
steps 2 and 3 then belongs to test mode.

## 2. Create a restricted key

The app only needs to open and read Checkout Sessions, so give it a key that
can do nothing else.

1. **Developers → API keys** (*Desenvolvedores → Chaves da API*).
2. **Create restricted key** (*Criar chave restrita*).
3. **Key name** (*Nome da chave*): e.g. `hll-vip-shop`.
4. Type `Checkout` in **Filter resources** (*Filtrar recursos*).
5. On the **Checkout Sessions** row, pick **Write** (*Gravação*). Leave every
   other resource on **None** (*Nenhum*).
6. **Create key** (*Criar chave*) and copy the key. It starts with
   `rk_test_`.

> [!TIP]
> The standard secret key (`sk_test_…`) works too, but it can do anything on
> the account. A restricted key leaked from the app can only open checkouts.

## 3. Register the webhook

1. Open **Workbench → Webhooks** (the *Desenvolvedores* bar at the bottom of
   the dashboard) and **Create an event destination** (*Criar um destino de
   evento*).
2. **Events from**: **Your account** (*Sua conta*).
3. Search `checkout.session` and tick these four events:

   | Event | What the app does |
   | --- | --- |
   | `checkout.session.completed` | Marks the order paid when the payment is done |
   | `checkout.session.async_payment_succeeded` | Same, for methods that settle later |
   | `checkout.session.async_payment_failed` | Cancels the order |
   | `checkout.session.expired` | Cancels the order the customer abandoned |

4. **Continue** → destination type **Webhook endpoint** (*Endpoint de
   webhook*) → **Continue**.
5. **Endpoint URL** (*URL do endpoint*): the address shown in the app
   under *Webhook URL to register with the provider*, e.g.
   `https://your-site.example/webhooks/stripe`.
6. **Create destination** (*Criar destino*).
7. On the destination's page, reveal the **Signing secret** (*Segredo da
   assinatura*) and copy it. It starts with `whsec_`.

## 4. Fill in the app

**VIP shop → Settings → Payments → Stripe → Configure**:

| Field | Value |
| --- | --- |
| Offer this payment method | On |
| Mode | *Test (sandbox)*. With Stripe the key decides the mode; keep this matching it |
| Secret key | The `rk_test_…` key from step 2 |
| Webhook signing secret | The `whsec_…` secret from step 3 |

**Save**. The Stripe card now shows **Test mode**.

## 5. Make a test purchase

Buy a package in the shop and pay with Stripe's test card:

| Card number | Expiry | CVC |
| --- | --- | --- |
| `4242 4242 4242 4242` | Any future date | Any 3 digits |

Then check:

- **VIP shop → Purchases** shows the order as paid.
- In Stripe, **Workbench → Webhooks → (your destination) → Event
  deliveries** (*Entregas de eventos*) shows `checkout.session.completed`
  answered with **200**.

## 6. Going live

1. Leave test mode in the Stripe dashboard. Stripe asks you to finish
   activating the account first.
2. Repeat steps 2 and 3 in live mode. The key now starts with `rk_live_` and
   the webhook has **its own** `whsec_…` secret.
3. In the app, paste both, set **Mode** to *Live* and save.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Checkout does not open: *"Invalid API Key provided"* | The key was deleted or mistyped |
| Checkout does not open: *"The provided key … does not have the required permissions"* | The restricted key lacks **Checkout Sessions: Write** |
| Paid in Stripe, still pending in the app, log says `bad signature` | The signing secret is from another destination, or from the other mode |
| Stripe shows the delivery failing with a timeout | The app is not reachable at that URL (tunnel down, wrong domain) |

More in [When a payment does not arrive](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#when-a-payment-does-not-arrive).

***

**←** [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) · [Dodo Payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Dodo-Payments) **→**
