defmodule HllConditionalActions.VipShop.Package do
  @moduledoc """
  A VIP package: what it costs, how long it lasts and which servers it
  grants VIP on. A package with several servers grants VIP on every one of
  them from a single purchase. No duration means permanent VIP.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{}

  schema "vip_packages" do
    field :name, :string
    field :description, :string
    field :price_cents, :integer
    field :currency, :string
    field :duration_days, :integer
    field :active, :boolean, default: true
    field :position, :integer, default: 0
    field :highlight, :string
    field :compare_at_cents, :integer
    field :updated_by, :string
    field :archived_at, :utc_datetime

    # Filled from the form; `price_cents` is what is stored.
    field :price, :decimal, virtual: true
    field :compare_at, :decimal, virtual: true

    many_to_many :servers, Server, join_through: "vip_package_servers", on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changes a package. `servers` are the server structs it grants VIP on.
  """
  def changeset(package, attrs, servers) do
    package
    |> cast(attrs, [
      :name,
      :description,
      :price,
      :compare_at,
      :currency,
      :duration_days,
      :active,
      :position,
      :highlight
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
    |> put_price_cents()
    |> put_compare_at_cents()
    |> validate_length(:highlight, max: 30)
    |> validate_required([:name, :price_cents, :currency])
    |> validate_length(:name, max: 80)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_number(:price_cents, greater_than: 0)
    |> validate_number(:duration_days, greater_than: 0, less_than_or_equal_to: 3650)
    |> put_assoc(:servers, servers)
    |> then(fn changeset ->
      if servers == [],
        do: add_error(changeset, :servers, "pick at least one server"),
        else: changeset
    end)
  end

  @doc """
  The price as a decimal, for forms and display.

      iex> HllConditionalActions.VipShop.Package.price(%HllConditionalActions.VipShop.Package{price_cents: 1990})
      Decimal.new("19.90")
  """
  @spec price(t()) :: Decimal.t() | nil
  def price(%__MODULE__{price_cents: nil}), do: nil

  def price(%__MODULE__{price_cents: cents}),
    do: cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)

  @doc """
  The "was" price shown struck through, as a decimal, or nil.
  """
  @spec compare_at(t()) :: Decimal.t() | nil
  def compare_at(%__MODULE__{compare_at_cents: nil}), do: nil

  def compare_at(%__MODULE__{compare_at_cents: cents}),
    do: cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)

  # A blank "was" price clears it; one not above the price is ignored.
  defp put_compare_at_cents(changeset) do
    case fetch_change(changeset, :compare_at) do
      {:ok, nil} ->
        put_change(changeset, :compare_at_cents, nil)

      {:ok, amount} ->
        cents = amount |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
        price = get_field(changeset, :price_cents) || 0
        put_change(changeset, :compare_at_cents, if(cents > price, do: cents))

      :error ->
        changeset
    end
  end

  defp put_price_cents(changeset) do
    case get_change(changeset, :price) do
      nil ->
        changeset

      price ->
        cents = price |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
        put_change(changeset, :price_cents, cents)
    end
  end
end
