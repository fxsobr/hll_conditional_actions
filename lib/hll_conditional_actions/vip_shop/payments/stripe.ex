defmodule HllConditionalActions.VipShop.Payments.Stripe do
  @moduledoc """
  Stripe Checkout.

  A Checkout Session is created per order, with the order id as
  `client_reference_id`. Stripe then calls `/webhooks/stripe` with
  `checkout.session.completed` (or the async success/failure events for
  methods like Boleto), signed with the endpoint's secret in the
  `Stripe-Signature` header.

  Test and live mode are decided by the key itself (`sk_test_` or
  `sk_live_`), so `mode` here is informational.
  """

  @behaviour HllConditionalActions.VipShop.Payments

  alias HllConditionalActions.VipShop.Payments

  @api "https://api.stripe.com/v1"
  # How old a signed webhook may be before it is refused as a replay.
  @tolerance_seconds 300

  @impl true
  def checkout(provider, order, urls) do
    form = [
      {"mode", "payment"},
      {"success_url",
       urls.success <> separator(urls.success) <> "session_id={CHECKOUT_SESSION_ID}"},
      {"cancel_url", urls.cancel},
      {"client_reference_id", to_string(order.id)},
      {"metadata[order_id]", to_string(order.id)},
      {"line_items[0][quantity]", "1"},
      {"line_items[0][price_data][currency]", String.downcase(order.currency)},
      {"line_items[0][price_data][unit_amount]", to_string(order.amount_cents)},
      {"line_items[0][price_data][product_data][name]",
       "#{order.package_name} - #{order.player_name || order.player_id}"}
    ]

    form = if urls[:email], do: [{"customer_email", urls.email} | form], else: form

    case provider |> client() |> Req.post(url: "/checkout/sessions", form: form) do
      {:ok, %{status: 200, body: %{"id" => id, "url" => url}}} -> {:ok, %{url: url, ref: id}}
      {:ok, %{body: %{"error" => %{"message" => message}}}} -> {:error, message}
      {:ok, %{status: status}} -> {:error, "Stripe answered HTTP #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @impl true
  def handle_webhook(provider, %{raw_body: body, signature: signature}, _params) do
    with :ok <- verify(provider.credentials["webhook_secret"], body, signature),
         {:ok, event} <- Jason.decode(body) do
      {:ok, outcome(event)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "not JSON"}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def confirm(provider, %{"session_id" => id}) when is_binary(id) do
    case provider |> client() |> Req.get(url: "/checkout/sessions/#{URI.encode(id)}") do
      {:ok, %{status: 200, body: %{"payment_status" => "paid"}}} ->
        {:ok, {:paid, {:provider_ref, id}}}

      {:ok, %{status: 200}} ->
        {:ok, :ignore}

      {:ok, %{status: status}} ->
        {:error, "Stripe answered HTTP #{status}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def confirm(_provider, _params), do: {:ok, :ignore}

  # Listing sessions is exactly what a restricted key with "Checkout
  # Sessions: write" may do, so this also catches a key missing that right.
  @impl true
  def check_credentials(provider) do
    case provider |> client() |> Req.get(url: "/checkout/sessions", params: [limit: 1]) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: %{"error" => %{"message" => message}}}} -> {:error, message}
      {:ok, %{status: status}} -> {:error, "Stripe answered HTTP #{status}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp outcome(%{"type" => type, "data" => %{"object" => %{"id" => id} = session}})
       when type in ["checkout.session.completed", "checkout.session.async_payment_succeeded"] do
    if session["payment_status"] == "paid", do: {:paid, {:provider_ref, id}}, else: :ignore
  end

  defp outcome(%{"type" => "checkout.session.expired", "data" => %{"object" => %{"id" => id}}}),
    do: {:canceled, {:provider_ref, id}, "checkout expired"}

  defp outcome(%{
         "type" => "checkout.session.async_payment_failed",
         "data" => %{"object" => %{"id" => id}}
       }),
       do: {:canceled, {:provider_ref, id}, "payment failed"}

  defp outcome(_event), do: :ignore

  @doc ~S"""
  Checks a `Stripe-Signature` header against the raw body.

      iex> alias HllConditionalActions.VipShop.Payments.Stripe
      iex> now = System.system_time(:second)
      iex> sig = HllConditionalActions.VipShop.Payments.hmac_hex("whsec", "#{now}.{}")
      iex> Stripe.verify("whsec", "{}", "t=#{now},v1=#{sig}")
      :ok
      iex> Stripe.verify("whsec", "{}", "t=#{now},v1=bad")
      {:error, "bad signature"}
  """
  @spec verify(String.t() | nil, String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def verify(secret, body, header) when is_binary(secret) and is_binary(header) do
    parts = header |> String.split(",") |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        [k, v] -> k == "t" && v
        _other -> nil
      end)

    signatures = for [k, v] <- parts, k == "v1", do: v

    with {ts, ""} <- Integer.parse(timestamp || ""),
         true <-
           abs(System.system_time(:second) - ts) <= @tolerance_seconds || {:error, "too old"} do
      expected = Payments.hmac_hex(secret, "#{ts}.#{body}")

      if Enum.any?(signatures, &Payments.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, "bad signature"}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, "malformed signature header"}
    end
  end

  def verify(_secret, _body, _header), do: {:error, "missing signature or webhook secret"}

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")

  defp client(provider) do
    Payments.req(
      base_url: @api,
      auth: {:bearer, provider.credentials["secret_key"]},
      retry: false
    )
  end
end
