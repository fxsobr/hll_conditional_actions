🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) / [Dodo Payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Dodo-Payments)
***

# Setting up Dodo Payments

## Menu

- [What you need](#what-you-need)
- [1. Switch the dashboard to test mode](#1-switch-the-dashboard-to-test-mode)
- [2. Create an API key](#2-create-an-api-key)
- [3. Register the webhook](#3-register-the-webhook)
- [4. Fill in the app](#4-fill-in-the-app)
- [5. Make a test purchase](#5-make-a-test-purchase)
- [6. Going live](#6-going-live)
- [The VIP product the app creates](#the-vip-product-the-app-creates)
- [Troubleshooting](#troubleshooting)

***

[Dodo Payments](https://dodopayments.com) is a *merchant of record*: it sells
to the customer on your behalf and handles the taxes. For payments in reais it
offers **Pix** and cards on its checkout page.

## What you need

- A Dodo Payments account. The dashboard may be in Portuguese; labels are
  given below as *English (Português)*.
- The app reachable from the internet over HTTPS (for local tests, see
  [Trying webhooks on your own computer](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#trying-webhooks-on-your-own-computer)).

## 1. Switch the dashboard to test mode

At the bottom of the dashboard's left menu, pick **Test mode** (*Modo de
teste*). A banner confirms it. Test mode and live mode are separate: keys,
webhooks and products made in one do not exist in the other.

## 2. Create an API key

1. **Developer → API Keys** (*Desenvolvedor → Chaves de API*), or
   <https://app.dodopayments.com/developer/api-keys>.
2. **Add API Key** (*Adicionar chave de API*).
3. **Name** (*Nome da chave de API*): e.g. `HLL VIP shop`.
4. Tick **Enable write access** (*Ativar acesso de gravação*). The app needs
   it to create the VIP product and the checkouts.
5. **Create** (*Criar*) and copy the key. **It is shown only once.**

## 3. Register the webhook

1. **Developer → Webhooks** (*Desenvolvedor → Webhooks*), or
   <https://app.dodopayments.com/developer/webhooks>.
2. **Add endpoint** (*Adicionar endpoint*).
3. **Endpoint URL** (*URL do endpoint*): the address shown in the app, e.g.
   `https://your-site.example/webhooks/dodo`.
4. **Description**: optional, e.g. `HLL VIP shop`.
5. **Subscribed events** (*Eventos subscritos*): search `payment.` and tick
   the **payment** group, which gives the four events below. The app acts on
   `payment.succeeded`; the others are accepted and ignored.

   `payment.succeeded` · `payment.failed` · `payment.processing` ·
   `payment.cancelled`

6. **Create endpoint** (*Criar endpoint*).
7. On the endpoint's page, under **Signing secret** (*Segredo de assinatura*),
   click the eye to show it and copy it. It starts with `whsec_`.

## 4. Fill in the app

**VIP shop → Settings → Payments → Dodo Payments → Configure**:

| Field | Value |
| --- | --- |
| Offer this payment method | On |
| Mode | *Test (sandbox)* — **must match** the dashboard mode the key came from |
| API key | The key from step 2 |
| Webhook signing secret | The `whsec_…` secret from step 3 |

**Save**. The Dodo Payments card now shows **Test mode**.

## 5. Make a test purchase

Buy a package in the shop and choose Dodo Payments. The checkout page shows a
**Test card** (*Cartão de Teste*) helper with the cards to use; the usual one
is:

| Card number | Expiry | CVC |
| --- | --- | --- |
| `4242 4242 4242 4242` | Any future date | Any 3 digits |

Fill in any name and billing address. Then check:

- **VIP shop → Purchases** shows the order as paid.
- In Dodo, **Developer → Webhooks → (your endpoint)** lists a
  `payment.succeeded` attempt answered with **200**.

## 6. Going live

1. Finish the account verification Dodo asks for (the dashboard shows it as
   *Action required*). Live mode stays locked until then.
2. Switch the dashboard to **Live mode** (*Modo ao vivo*) and repeat steps 2
   and 3. The live key and the live webhook secret are new values.
3. In the app, paste both, set **Mode** to *Live* and save.

## The VIP product the app creates

Dodo only charges for products registered on its side. So the first time a
customer checks out, the app creates **one product called `VIP`** with a free
("pay what you want") price in the shop's currency, and charges each order's
own amount on it. You will see it under **Products** in the dashboard.

- It is created once per mode and currency, and reused afterwards.
- **Do not delete or archive it.** If it is gone, checkouts fail until a new
  API key is saved in the app — saving a different key makes the app create
  the product again.
- Changing the shop's currency creates a second product for the new currency.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Checkout does not open, log shows `Dodo answered HTTP 401` | The key belongs to the other mode, or was deleted. Check **Mode** |
| Checkout does not open with a permission error | The key was created without **write access**: create a new one with it ticked |
| Paid in Dodo, still pending in the app, log says `bad signature` | The secret is from another endpoint or the other mode |
| Log says `malformed webhook headers` | Something between Dodo and the app (a proxy) strips the `webhook-*` headers |

More in [When a payment does not arrive](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#when-a-payment-does-not-arrive).

***

**←** [Stripe](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Stripe) · [Mercado Pago](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Mercado-Pago) **→**
