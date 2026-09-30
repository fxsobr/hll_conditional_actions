defmodule HllConditionalActions.VipShop.Payments do
  @moduledoc """
  The payment providers behind one interface.

  A provider turns a pending order into a checkout page (`checkout/3`) and
  reports back which order a notification is about and whether it is paid
  (`handle_webhook/3`, `confirm/2`). The shop only ever marks an order paid
  from what the provider's own API says, never from what the browser or an
  unverified request claims.
  """

  alias HllConditionalActions.VipShop.{Order, PaymentProvider}

  @typedoc "What a provider reports about an order."
  @type outcome :: {:paid, order_ref()} | {:canceled, order_ref(), String.t()} | :ignore
  @typedoc "How the provider points at an order: our id, or its own reference."
  @type order_ref :: {:order_id, term()} | {:provider_ref, String.t()}

  @callback checkout(PaymentProvider.t(), Order.t(), map()) ::
              {:ok, %{url: String.t(), ref: String.t()}} | {:error, String.t()}
  @callback handle_webhook(PaymentProvider.t(), map(), map()) ::
              {:ok, outcome()} | {:error, String.t()}
  @callback confirm(PaymentProvider.t(), map()) :: {:ok, outcome()} | {:error, String.t()}
  @doc "Tries the stored keys with a harmless read, so a typo shows up on save."
  @callback check_credentials(PaymentProvider.t()) :: :ok | {:error, String.t()}

  @doc "The module implementing a provider."
  @spec module(String.t()) :: module()
  def module("stripe"), do: HllConditionalActions.VipShop.Payments.Stripe
  def module("dodo"), do: HllConditionalActions.VipShop.Payments.Dodo
  def module("mercado_pago"), do: HllConditionalActions.VipShop.Payments.MercadoPago

  @doc false
  # The Req client every provider uses, with test stubs merged in from
  # `:payment_req_options` the way the CRCON client does.
  @spec req(keyword()) :: Req.Request.t()
  def req(opts) do
    opts
    |> Req.new()
    |> Req.merge(Application.get_env(:hll_conditional_actions, :payment_req_options, []))
  end

  @doc """
  Constant-time comparison of two signatures.

      iex> HllConditionalActions.VipShop.Payments.secure_compare("abc", "abc")
      true
      iex> HllConditionalActions.VipShop.Payments.secure_compare("abc", "abd")
      false
  """
  @spec secure_compare(String.t(), String.t()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  def secure_compare(_a, _b), do: false

  @doc "HMAC-SHA256 of a payload, hex encoded in lower case."
  @spec hmac_hex(String.t(), String.t()) :: String.t()
  def hmac_hex(secret, payload),
    do: :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
end
