defmodule HllConditionalActionsWeb.ShopPaymentController do
  @moduledoc """
  Where payment providers send people and notifications back.

    * `return/2` - the customer's browser comes back from the checkout page.
      The provider's API is asked whether the order is paid, so the page can
      say so at once instead of waiting for the webhook.
    * `webhook/2` - the provider's server-to-server notification, verified
      by the provider module before anything is marked.

  Both may report the same payment; `VipShop.mark_paid/1` only acts once.
  """

  use HllConditionalActionsWeb, :controller

  require Logger

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{PaymentProvider, Payments}

  # Only providers with an implementation have a return page or a webhook.
  plug :known_provider

  def return(conn, %{"provider" => provider} = params) do
    record = VipShop.get_provider(provider)

    if record.enabled do
      case Payments.module(provider).confirm(record, params) do
        {:ok, outcome} -> VipShop.apply_outcome(provider, outcome)
        {:error, reason} -> Logger.warning("[shop] #{provider} return not confirmed: #{reason}")
      end
    end

    # The order's own page follows the payment and the VIP live. An admin's
    # test purchase goes back to the payments page it was started from.
    case params do
      %{"test" => "1"} ->
        redirect(conn, to: ~p"/vip-shop/settings/payments")

      %{"order" => id} when is_binary(id) and id != "" ->
        redirect(conn, to: ~p"/shop/orders/#{id}")

      _none ->
        redirect(conn, to: ~p"/shop/account")
    end
  end

  def webhook(conn, %{"provider" => provider} = params) do
    record = VipShop.get_provider(provider)

    request = %{
      raw_body: conn.assigns[:raw_body] || "",
      signature: header(conn, provider),
      headers: Map.new(conn.req_headers),
      request_id: List.first(get_req_header(conn, "x-request-id"))
    }

    with true <- record.enabled || {:error, "provider disabled"},
         {:ok, outcome} <- Payments.module(provider).handle_webhook(record, request, params) do
      order_id =
        case VipShop.apply_outcome(provider, outcome) do
          {:ok, %{id: id}} -> id
          _none -> nil
        end

      VipShop.record_webhook(provider, {:ok, event_name(params)}, %{order_id: order_id})
      send_resp(conn, 200, "ok")
    else
      {:error, reason} ->
        Logger.warning("[shop] #{provider} webhook refused: #{reason}")
        VipShop.record_webhook(provider, {:error, reason}, %{event: event_name(params)})
        send_resp(conn, 400, "")
    end
  end

  defp known_provider(%{params: %{"provider" => provider}} = conn, _opts) do
    if PaymentProvider.available?(provider), do: conn, else: conn |> send_resp(404, "") |> halt()
  end

  # Stripe and Dodo name the event in "type"; Mercado Pago in "action"
  # ("payment.updated"), with "type" holding only the topic.
  defp event_name(params), do: params["action"] || params["type"] || params["topic"]

  defp header(conn, "stripe"), do: List.first(get_req_header(conn, "stripe-signature"))
  defp header(conn, _provider), do: List.first(get_req_header(conn, "x-signature"))
end
