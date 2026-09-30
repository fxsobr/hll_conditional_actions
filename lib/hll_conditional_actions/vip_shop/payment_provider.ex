defmodule HllConditionalActions.VipShop.PaymentProvider do
  @moduledoc """
  A payment method the shop can offer, with its credentials.

  Each provider asks for different keys (see `fields/1`), so they are kept as
  one encrypted map. `mode` picks the provider's sandbox or its live account,
  which lets an admin try a purchase end to end before taking real money.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Encrypted

  @type t :: %__MODULE__{}

  # Order is the order of the shop's payment marketplace. Only the providers
  # with an implementation can be switched on; the rest are listed as coming.
  @providers ~w(stripe dodo mercado_pago)
  @available ~w(stripe dodo mercado_pago)
  @modes ~w(test live)

  schema "vip_payment_providers" do
    field :provider, :string
    field :enabled, :boolean, default: false
    field :mode, :string, default: "test"
    field :credentials, Encrypted.Map, redact: true

    # Health, written by the app itself (never by the admin's form).
    field :checked_at, :utc_datetime
    field :check_error, :string
    field :last_webhook_at, :utc_datetime
    field :last_webhook_event, :string
    field :last_webhook_error_at, :utc_datetime
    field :last_webhook_error, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Every payment provider, in display order."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "Whether a provider is implemented and can be enabled."
  @spec available?(String.t()) :: boolean()
  def available?(provider), do: provider in @available

  @doc "The sandbox and live modes."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  The credentials a provider needs, in form order.

      iex> HllConditionalActions.VipShop.PaymentProvider.fields("stripe")
      ["secret_key", "webhook_secret"]
  """
  @spec fields(String.t()) :: [String.t()]
  def fields("stripe"), do: ~w(secret_key webhook_secret)
  def fields("dodo"), do: ~w(api_key webhook_secret)
  def fields("mercado_pago"), do: ~w(access_token webhook_secret)

  @doc """
  The credentials that must be filled before a provider can be switched on.
  Mercado Pago's webhook secret is optional: every notification is confirmed
  with its API anyway.

      iex> HllConditionalActions.VipShop.PaymentProvider.required_fields("dodo")
      ["api_key", "webhook_secret"]
      iex> HllConditionalActions.VipShop.PaymentProvider.required_fields("mercado_pago")
      ["access_token"]
  """
  @spec required_fields(String.t()) :: [String.t()]
  def required_fields("mercado_pago"), do: ["access_token"]
  def required_fields(provider), do: fields(provider)

  @doc """
  Changes a provider. Blank credential fields keep what is stored, so the
  form never has to show a secret back. Data a provider keeps for itself
  next to the credentials (such as Dodo's product ids) survives an edit,
  unless the key it belongs to changes.
  """
  def changeset(provider, attrs) do
    stored = provider.credentials || %{}
    given = Map.get(attrs, "credentials") || Map.get(attrs, :credentials) || %{}
    fields = fields(provider.provider)

    credentials =
      fields
      |> Map.new(fn field ->
        case Map.get(given, field) do
          value when is_binary(value) and value != "" -> {field, String.trim(value)}
          _blank -> {field, Map.get(stored, field)}
        end
      end)
      |> Map.reject(fn {_field, value} -> is_nil(value) end)

    kept = if key_changed?(stored, credentials), do: %{}, else: Map.drop(stored, fields)
    credentials = Map.merge(kept, credentials)

    provider
    |> cast(attrs, [:enabled, :mode])
    |> put_change(:credentials, credentials)
    |> put_stripe_mode()
    |> validate_inclusion(:mode, @modes)
    |> validate_enable()
  end

  # Stripe has no separate test host: `sk_test_`/`rk_test_` keys are test
  # mode, `_live_` keys are live. Following the key keeps the badge honest.
  defp put_stripe_mode(changeset) do
    with "stripe" <- get_field(changeset, :provider),
         key when is_binary(key) <- (get_field(changeset, :credentials) || %{})["secret_key"] do
      put_change(changeset, :mode, if(String.contains?(key, "_live_"), do: "live", else: "test"))
    else
      _other -> changeset
    end
  end

  # The key that identifies the account; data kept for one account means
  # nothing on another.
  defp key_changed?(stored, credentials) do
    Enum.any?(~w(secret_key api_key access_token), fn key ->
      Map.has_key?(stored, key) and stored[key] != credentials[key]
    end)
  end

  defp validate_enable(changeset) do
    provider = get_field(changeset, :provider)
    credentials = get_field(changeset, :credentials) || %{}

    cond do
      not get_field(changeset, :enabled) ->
        changeset

      not available?(provider) ->
        add_error(changeset, :enabled, "is not available for this provider yet")

      Enum.any?(required_fields(provider), &(Map.get(credentials, &1) in [nil, ""])) ->
        add_error(changeset, :enabled, "fill in every credential first")

      true ->
        changeset
    end
  end
end
