🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [User Guide](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide) / [Features](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features) / [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) / [Mercado Pago](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Mercado-Pago)
***

# Setting up Mercado Pago

## Menu

- [What you need](#what-you-need)
- [1. Create the application](#1-create-the-application)
- [2. Copy the test access token](#2-copy-the-test-access-token)
- [3. Register the webhook](#3-register-the-webhook)
- [4. Fill in the app](#4-fill-in-the-app)
- [5. Check the webhook](#5-check-the-webhook)
- [6. Make a test purchase](#6-make-a-test-purchase)
- [7. Going live](#7-going-live)
- [Troubleshooting](#troubleshooting)

***

The shop uses **Checkout Pro**: the customer pays on Mercado Pago's page with
Pix, a card or boleto, and Mercado Pago tells the app through a webhook.
Every notification is checked back with Mercado Pago's API before anything is
marked paid.

## What you need

- A Mercado Pago account, and access to
  [Mercado Pago Developers](https://www.mercadopago.com.br/developers/panel/app).
- The app reachable from the internet over HTTPS (for local tests, see
  [Trying webhooks on your own computer](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#trying-webhooks-on-your-own-computer)).

The panel is in Portuguese in Brazil; labels are given as they appear there.

## 1. Create the application

1. **Suas integrações → Criar aplicação**, or
   <https://www.mercadopago.com.br/developers/panel/app/create-app>. (If the
   panel offers to create it with an AI agent, go **Voltar** to reach the
   form.)
2. **Escolha uma solução para integrar**: **Checkout Pro**.
3. **Outros dados**:
   - **Tipo de API**: **API de Preferences** — the one the app uses.
   - **Nome da aplicação**: e.g. `HLL VIP shop`.
4. Accept the terms and **Criar aplicação**.

## 2. Copy the test access token

1. In the application, **Credenciais de teste**.
2. Next to **Access Token**, click the eye and copy the value.

In current accounts the test credentials belong to a **test seller** the panel
created for the application, so the token starts with `APP_USR-` even though
it is a test token. Older accounts show `TEST-…`; both work.

## 3. Register the webhook

1. In the application, **Webhooks → Configurar notificações**.
2. Tab **Modo de teste**. In **URL para teste** paste the address shown in the
   app, e.g. `https://your-site.example/webhooks/mercado_pago`. (The field
   already shows `https://` — do not type it twice.)
3. Under **Eventos recomendados para integrações com Checkout Pro**, tick
   **Pagamentos** only.
4. **Salvar configurações**, then **Salvar** in the confirmation.
5. The page now shows an **Assinatura secreta**. Click the eye and copy it.
   Do not click the circular arrow next to it: that makes a new secret.

## 4. Fill in the app

**VIP shop → Payments → Mercado Pago → Configure**:

| Field | Value |
| --- | --- |
| Mode | *In test* — the customer is sent to the sandbox checkout |
| Access token | The token from step 2 |
| Webhook signing secret | The *Assinatura secreta* from step 3. Optional — without it the app still confirms every payment with the API — but set it, so forged notifications are refused before that |

**Test connection**, then **Save**. The Mercado Pago card now shows **In test**; if it still says *Off*, click **Off · turn on**.

## 5. Check the webhook

Back in **Webhooks → Configurar notificações**, click **Simular
notificação**, pick **Pagamentos** as *Tipo de evento* and **Enviar teste**.

The result must be **200 - OK**. The simulated payment id does not exist, so
the app accepts the notification and does nothing with it. A **400** means the
signature did not match (copy the secret again); no answer means the URL is
not reachable.

## 6. Make a test purchase

Mercado Pago only accepts test payments from **test buyers**. Paying while
logged in to your real account fails with *"A transação não aceita este meio
de pagamento"*.

1. In the application, **Contas de teste → Criar conta de teste**, type
   **Comprador**, country Brazil. Note its user and password.
2. Open the shop in a **private window**, buy a package, choose Mercado Pago,
   and log in on Mercado Pago's page with the test buyer.
3. Pay with a test card from **Cartões de teste**, for example:

   | Card | Number | CVV | Expiry | Holder name | CPF |
   | --- | --- | --- | --- | --- | --- |
   | Mastercard | `5031 4332 1540 6351` | `123` | `11/30` | `APRO` | `12345678909` |

   The holder name decides the result: **APRO** approves, **OTHE** declines.
4. Check **VIP shop → Purchases**: the order shows as paid. In the panel,
   **Webhooks** lists the notification with **200**.

## 7. Going live

1. **Credenciais de produção**: activate them (Mercado Pago asks for a few
   details about the business) and copy the production **Access Token**
   (`APP_USR-…`).
2. **Webhooks → Configurar notificações → Modo de produção**: paste the same
   URL, tick **Pagamentos**, save, and copy that mode's **Assinatura
   secreta**.
3. In the app, paste both, set **Mode** to *Production* and save. The customer is
   now sent to the real checkout.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Checkout does not open: *"invalid access token"* | Token mistyped, or from the other mode |
| *"A transação não aceita este meio de pagamento"* on the sandbox checkout | You are logged in with a real account; use a test buyer |
| Log says `bad signature` | The *Assinatura secreta* is from the other mode, or was regenerated |
| Paid, still pending in the app, no webhook in the panel | **Pagamentos** is not ticked, or the URL is wrong for that mode |

More in [When a payment does not arrive](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments#when-a-payment-does-not-arrive).

***

**←** [Dodo Payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments-%E2%80%90-Dodo-Payments) · **↑** [VIP shop payments](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-VIP-shop-payments) · [Inbox and history](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Features-%E2%80%90-Attention-and-history) **→**
