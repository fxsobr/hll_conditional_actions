defmodule HllConditionalActions.VipShop.Payments.Dodo do
  @moduledoc """
  Dodo Payments checkout sessions.

  Dodo sells products, not free amounts, so the shop keeps one
  pay-what-you-want product per currency and charges each order's price on
  it. The product is created on the first checkout and its id kept with the
  provider's credentials (`product:<mode>:<currency>`).

  A checkout session is opened per order with the order id in `metadata`.
  Dodo then calls `/webhooks/dodo` with `payment.succeeded`, signed the
  Standard Webhooks way (`webhook-id`, `webhook-timestamp` and
  `webhook-signature` headers). The customer comes back with `payment_id`
  in the query, which is fetched from the API before anything is marked.

  `mode` picks the host: test mode and live mode are separate accounts with
  separate keys.
  """

  @behaviour HllConditionalActions.VipShop.Payments

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Payments

  @hosts %{"test" => "https://test.dodopayments.com", "live" => "https://live.dodopayments.com"}
  # How old a signed webhook may be before it is refused as a replay.
  @tolerance_seconds 300
  # The lowest price the pay-what-you-want product accepts; the order's own
  # amount is always sent, so this only has to stay below every package.
  @minimum_price 100

  @impl true
  def checkout(provider, order, urls) do
    with {:ok, product_id} <- product(provider, order.currency) do
      body =
        %{
          product_cart: [%{product_id: product_id, quantity: 1, amount: order.amount_cents}],
          return_url: urls.success,
          metadata: %{order_id: to_string(order.id)}
        }
        |> put_customer(urls[:email])

      case provider |> client() |> Req.post(url: "/checkouts", json: body) do
        {:ok, %{status: status, body: %{"session_id" => id, "checkout_url" => url}}}
        when status in 200..201 and is_binary(url) ->
          {:ok, %{url: url, ref: id}}

        {:ok, response} ->
          {:error, error_message(response)}

        {:error, error} ->
          {:error, Exception.message(error)}
      end
    end
  end

  @impl true
  def handle_webhook(provider, %{raw_body: body, headers: headers}, _params) do
    with :ok <- verify(provider.credentials["webhook_secret"], body, headers),
         {:ok, event} <- Jason.decode(body) do
      {:ok, outcome(event)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "not JSON"}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_webhook(_provider, _request, _params), do: {:error, "missing webhook headers"}

  @impl true
  def confirm(provider, %{"payment_id" => id}) when is_binary(id) and id != "" do
    case provider |> client() |> Req.get(url: "/payments/#{URI.encode(id)}") do
      {:ok, %{status: 200, body: payment}} ->
        {:ok, outcome(%{"type" => "payment", "data" => payment})}

      {:ok, response} ->
        {:error, error_message(response)}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def confirm(_provider, _params), do: {:ok, :ignore}

  @impl true
  def check_credentials(provider) do
    case provider |> client() |> Req.get(url: "/products", params: [page_size: 1]) do
      {:ok, %{status: 200}} -> :ok
      {:ok, response} -> {:error, error_message(response)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # Only a finished payment moves an order. A declined card or an abandoned
  # Pix leaves the session open for another try, so failures are not
  # treated as cancellations; the order simply stays pending.
  defp outcome(%{"type" => type, "data" => %{"status" => "succeeded"} = payment})
       when type in ["payment.succeeded", "payment"] do
    case payment do
      %{"metadata" => %{"order_id" => id}} when is_binary(id) -> {:paid, {:order_id, id}}
      %{"checkout_session_id" => ref} when is_binary(ref) -> {:paid, {:provider_ref, ref}}
      _unknown -> :ignore
    end
  end

  defp outcome(_event), do: :ignore

  # The pay-what-you-want product for a currency, created once.
  defp product(provider, currency) do
    key = "product:#{provider.mode}:#{currency}"

    case provider.credentials[key] do
      id when is_binary(id) -> {:ok, id}
      nil -> create_product(provider, currency, key)
    end
  end

  defp create_product(provider, currency, key) do
    body = %{
      name: "VIP",
      description: "VIP",
      tax_category: "digital_products",
      price: %{
        type: "one_time_price",
        currency: currency,
        price: @minimum_price,
        pay_what_you_want: true,
        purchasing_power_parity: false,
        tax_inclusive: true
      }
    }

    case provider |> client() |> Req.post(url: "/products", json: body) do
      {:ok, %{status: status, body: %{"product_id" => id}}} when status in 200..201 ->
        VipShop.put_provider_data(provider, key, id)
        {:ok, id}

      {:ok, response} ->
        {:error, error_message(response)}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp put_customer(body, email) when is_binary(email) and email != "",
    do: Map.put(body, :customer, %{email: email})

  defp put_customer(body, _email), do: body

  @doc ~S"""
  Checks the Standard Webhooks headers against the raw body. The secret is
  shown as `whsec_` followed by the base64 signing key.

      iex> alias HllConditionalActions.VipShop.Payments.Dodo
      iex> secret = "whsec_" <> Base.encode64("key")
      iex> now = to_string(System.system_time(:second))
      iex> sig = :crypto.mac(:hmac, :sha256, "key", "msg_1.#{now}.{}") |> Base.encode64()
      iex> headers = %{"webhook-id" => "msg_1", "webhook-timestamp" => now}
      iex> Dodo.verify(secret, "{}", Map.put(headers, "webhook-signature", "v1,#{sig}"))
      :ok
      iex> Dodo.verify(secret, "{}", Map.put(headers, "webhook-signature", "v1,bad"))
      {:error, "bad signature"}
  """
  @spec verify(String.t() | nil, String.t(), map()) :: :ok | {:error, String.t()}
  def verify(secret, body, headers) when is_binary(secret) and is_map(headers) do
    with id when is_binary(id) <- headers["webhook-id"],
         {ts, ""} <- Integer.parse(headers["webhook-timestamp"] || ""),
         signatures when is_binary(signatures) <- headers["webhook-signature"],
         {:ok, key} <- signing_key(secret),
         true <-
           abs(System.system_time(:second) - ts) <= @tolerance_seconds || {:error, "too old"} do
      expected = :crypto.mac(:hmac, :sha256, key, "#{id}.#{ts}.#{body}") |> Base.encode64()

      signatures
      |> String.split(" ", trim: true)
      |> Enum.any?(fn
        "v1," <> signature -> Payments.secure_compare(signature, expected)
        _other -> false
      end)
      |> if(do: :ok, else: {:error, "bad signature"})
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, "malformed webhook headers"}
    end
  end

  def verify(_secret, _body, _headers), do: {:error, "missing signature or webhook secret"}

  defp signing_key("whsec_" <> encoded), do: signing_key(encoded)

  defp signing_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, "webhook secret is not base64"}
    end
  end

  defp error_message(%{status: status, body: %{"message" => message}}),
    do: "Dodo answered HTTP #{status}: #{message}"

  defp error_message(%{status: status, body: %{"code" => code}}),
    do: "Dodo answered HTTP #{status}: #{code}"

  defp error_message(%{status: status}), do: "Dodo answered HTTP #{status}"

  defp client(provider) do
    Payments.req(
      base_url: Map.fetch!(@hosts, provider.mode || "test"),
      auth: {:bearer, provider.credentials["api_key"]},
      retry: false
    )
  end
end
