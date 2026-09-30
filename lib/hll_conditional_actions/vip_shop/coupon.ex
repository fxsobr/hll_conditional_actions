defmodule HllConditionalActions.VipShop.Coupon do
  @moduledoc """
  A discount code customers type at checkout.

  `"percent"` takes `value` percent off (1-100); `"fixed"` takes `value`
  cents off, never below the provider's minimum of one cent. A coupon can
  expire and be limited to a number of uses; a use is only counted when the
  order is paid.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(percent fixed)

  schema "vip_coupons" do
    field :code, :string
    field :kind, :string, default: "percent"
    field :value, :integer
    field :expires_at, :utc_datetime
    field :max_uses, :integer
    field :uses, :integer, default: 0
    field :active, :boolean, default: true
    field :starts_at, :utc_datetime
    field :note, :string
    field :package_ids, {:array, :integer}, default: []
    field :once_per_customer, :boolean, default: false
    field :created_by, :string

    # Fixed discounts are typed as money; `value` holds the cents.
    field :amount, :decimal, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc "The coupon kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc false
  def changeset(coupon, attrs) do
    coupon
    |> cast(attrs, [
      :code,
      :kind,
      :value,
      :amount,
      :starts_at,
      :expires_at,
      :max_uses,
      :active,
      :note,
      :package_ids,
      :once_per_customer
    ])
    |> validate_length(:note, max: 120)
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> put_fixed_value()
    |> validate_required([:code, :kind, :value])
    |> validate_format(:code, ~r/^[A-Z0-9_-]{3,32}$/,
      message: "use 3 to 32 letters, numbers, - or _"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:value, greater_than: 0)
    |> validate_percent()
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:code, name: :vip_coupons_code_index)
  end

  @doc """
  The discount, in cents, a coupon gives on a price. Always leaves at least
  one cent to pay.

      iex> alias HllConditionalActions.VipShop.Coupon
      iex> Coupon.discount(%Coupon{kind: "percent", value: 10}, 1990)
      199
      iex> Coupon.discount(%Coupon{kind: "fixed", value: 5000}, 1990)
      1989
  """
  @spec discount(t(), pos_integer()) :: non_neg_integer()
  def discount(%__MODULE__{kind: "percent", value: value}, price),
    do: min(div(price * value, 100), price - 1)

  def discount(%__MODULE__{kind: "fixed", value: value}, price), do: min(value, price - 1)

  @doc "Whether a coupon can be used now."
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{} = coupon) do
    now = DateTime.utc_now()

    coupon.active and
      (is_nil(coupon.starts_at) or DateTime.compare(coupon.starts_at, now) != :gt) and
      (is_nil(coupon.expires_at) or DateTime.compare(coupon.expires_at, now) == :gt) and
      (is_nil(coupon.max_uses) or coupon.uses < coupon.max_uses)
  end

  @doc "Whether a coupon may be used on a package: an empty list means every package."
  @spec covers?(t(), term()) :: boolean()
  def covers?(%__MODULE__{package_ids: ids}, package_id),
    do: ids in [nil, []] or package_id in ids

  @doc """
  Where a coupon stands: `:active`, `:exhausted` (every use spent), `:expired`
  (past its end date), `:scheduled` (not started yet) or `:off`.
  """
  @spec state(t()) :: :active | :exhausted | :expired | :scheduled | :off
  def state(%__MODULE__{} = coupon) do
    now = DateTime.utc_now()

    cond do
      coupon.expires_at && DateTime.compare(coupon.expires_at, now) != :gt -> :expired
      coupon.max_uses && coupon.uses >= coupon.max_uses -> :exhausted
      not coupon.active -> :off
      coupon.starts_at && DateTime.compare(coupon.starts_at, now) == :gt -> :scheduled
      true -> :active
    end
  end

  defp put_fixed_value(changeset) do
    case {get_field(changeset, :kind), get_change(changeset, :amount)} do
      {"fixed", %Decimal{} = amount} ->
        put_change(
          changeset,
          :value,
          amount |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
        )

      _other ->
        changeset
    end
  end

  defp validate_percent(changeset) do
    if get_field(changeset, :kind) == "percent",
      do: validate_number(changeset, :value, less_than_or_equal_to: 100),
      else: changeset
  end
end
