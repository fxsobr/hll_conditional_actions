defmodule HllConditionalActions.VipShop.Order do
  @moduledoc """
  One purchase of a package for one player.

  The package's name, price and duration are copied in when the order is
  created, so editing or deleting a package never rewrites what somebody
  bought.

  ## Status

    * `"pending"` - waiting for the payment provider to confirm
    * `"paid"` - payment confirmed, VIP being granted
    * `"fulfilled"` - VIP granted on every server
    * `"partial"` - VIP granted on some servers; the rest failed
    * `"failed"` - paid, but no server accepted the VIP
    * `"canceled"` - the payment was refused or expired
    * `"refunded"` - the money went back and the VIP was removed
  """

  use Ecto.Schema

  alias HllConditionalActions.VipShop.{Customer, Grant, Package}

  @type t :: %__MODULE__{}

  @statuses ~w(pending paid fulfilled partial failed canceled refunded)

  schema "vip_orders" do
    field :package_name, :string
    field :player_id, :string
    field :player_name, :string
    field :amount_cents, :integer
    field :currency, :string
    field :duration_days, :integer
    field :provider, :string
    field :provider_ref, :string
    field :status, :string, default: "pending"
    field :paid_at, :utc_datetime
    field :fulfilled_at, :utc_datetime
    field :error, :string
    field :coupon_code, :string
    field :discount_cents, :integer, default: 0
    field :gift, :boolean, default: false
    field :granted_by, :string
    # An admin's purchase to try a payment method: not delivered, not revenue.
    field :test, :boolean, default: false
    # A manual grant has no package: these are its servers.
    field :server_ids, {:array, :integer}, default: []
    field :reason, :string
    field :receipt_sent_at, :utc_datetime
    field :refunded_at, :utc_datetime
    field :refunded_by, :string

    belongs_to :coupon, HllConditionalActions.VipShop.Coupon

    belongs_to :customer, Customer
    belongs_to :package, Package
    has_many :grants, Grant

    timestamps(type: :utc_datetime)
  end

  @doc "Every order status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
