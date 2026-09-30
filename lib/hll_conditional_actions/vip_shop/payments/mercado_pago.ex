defmodule HllConditionalActions.VipShop.Payments.MercadoPago do
  @moduledoc """
  Mercado Pago Checkout Pro.

  A preference is created per order with the order id as
  `external_reference`, and the customer pays on Mercado Pago's page (Pix,
  card, boleto...). Mercado Pago then notifies `/webhooks/mercado_pago` with
  a payment id; the payment is always fetched back from the API with the
  access token, so the notification itself is never trusted. When a webhook
  secret is set, the `x-signature` header is checked as well.

  In test mode the sandbox checkout page is used; the access token decides
  which account is charged.
  """

  @behaviour HllConditionalActions.VipShop.Payments

  alias HllConditionalActions.VipShop.Payments

  @api "https://api.mercadopago.com"

  @impl true
  def checkout(provider, order, urls) do
    body = %{
      external_reference: to_string(order.id),
      items: [
        %{
          title: "#{order.package_name} - #{order.player_name || order.player_id}",
          quantity: 1,
          unit_price: order.amount_cents / 100,
          currency_id: order.currency
        }
      ],
      back_urls: %{success: urls.success, failure: urls.cancel, pending: urls.success},
      auto_return: "approved",
      notification_url: urls.webhook
    }

    body = if urls[:email], do: Map.put(body, :payer, %{email: urls.email}), else: body

    case provider |> client() |> Req.post(url: "/checkout/preferences", json: body) do
      {:ok, %{status: status, body: %{"id" => id} = preference}} when status in 200..201 ->
        url =
          if provider.mode == "live",
            do: preference["init_point"],
            else: preference["sandbox_init_point"] || preference["init_point"]

        {:ok, %{url: url, ref: id}}

      {:ok, %{body: %{"message" => message}}} ->
        {:error, message}

      {:ok, %{status: status}} ->
        {:error, "Mercado Pago answered HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @impl true
  def handle_webhook(provider, request, params) do
    case payment_id(params) do
      nil ->
        {:ok, :ignore}

      id ->
        with :ok <- verify(provider.credentials["webhook_secret"], request, id) do
          fetch(provider, id)
        end
    end
  end

  @impl true
  def confirm(provider, %{"payment_id" => id}) when is_binary(id) and id != "",
    do: fetch(provider, id)

  def confirm(_provider, _params), do: {:ok, :ignore}

  @impl true
  def check_credentials(provider) do
    case provider |> client() |> Req.get(url: "/users/me") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: %{"message" => message}}} -> {:error, message}
      {:ok, %{status: status}} -> {:error, "Mercado Pago answered HTTP #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp payment_id(%{"type" => "payment", "data" => %{"id" => id}}), do: to_string(id)
  defp payment_id(%{"type" => "payment", "data.id" => id}), do: to_string(id)
  defp payment_id(%{"topic" => "payment", "id" => id}), do: to_string(id)
  defp payment_id(_params), do: nil

  defp fetch(provider, id) do
    case provider |> client() |> Req.get(url: "/v1/payments/#{URI.encode(id)}") do
      {:ok, %{status: 200, body: payment}} -> {:ok, outcome(payment)}
      # A payment the account does not have (the panel's "simulate" button
      # sends a made-up id) is nothing to act on; answering an error would
      # only make Mercado Pago retry it.
      {:ok, %{status: 404}} -> {:ok, :ignore}
      {:ok, %{status: status}} -> {:error, "Mercado Pago answered HTTP #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp outcome(%{"status" => "approved", "external_reference" => ref}) when is_binary(ref),
    do: {:paid, {:order_id, ref}}

  # A rejected card leaves the checkout open for another try, so it does not
  # cancel the order; a later approval must still be able to mark it paid.
  defp outcome(%{"status" => status, "external_reference" => ref})
       when status in ["cancelled", "refunded", "charged_back"] and is_binary(ref),
       do: {:canceled, {:order_id, ref}, "payment #{status}"}

  defp outcome(_payment), do: :ignore

  @doc ~S"""
  Checks the `x-signature` header when a webhook secret is configured.

      iex> alias HllConditionalActions.VipShop.Payments.MercadoPago
      iex> MercadoPago.verify(nil, %{}, "1")
      :ok
      iex> sig = HllConditionalActions.VipShop.Payments.hmac_hex("s", "id:1;request-id:r;ts:9;")
      iex> MercadoPago.verify("s", %{signature: "ts=9,v1=#{sig}", request_id: "r"}, "1")
      :ok
  """
  @spec verify(String.t() | nil, map(), String.t()) :: :ok | {:error, String.t()}
  def verify(secret, _request, _id) when secret in [nil, ""], do: :ok

  def verify(secret, %{signature: header, request_id: request_id}, id) when is_binary(header) do
    parts =
      Map.new(
        header
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2) |> List.to_tuple()))
      )

    manifest = "id:#{String.downcase(id)};request-id:#{request_id};ts:#{parts["ts"]};"

    if Payments.secure_compare(parts["v1"] || "", Payments.hmac_hex(secret, manifest)),
      do: :ok,
      else: {:error, "bad signature"}
  end

  def verify(_secret, _request, _id), do: {:error, "missing signature"}

  defp client(provider) do
    Payments.req(
      base_url: @api,
      auth: {:bearer, provider.credentials["access_token"]},
      retry: false
    )
  end
end
