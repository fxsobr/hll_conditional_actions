defmodule HllConditionalActions.VipShop.Grant do
  @moduledoc """
  The VIP an order granted on one server: `"pending"`, `"granted"` with the
  expiry CRCON was given, or `"failed"` with why.
  """

  use Ecto.Schema

  schema "vip_grants" do
    field :server_name, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :error, :string
    field :reminded_at, :utc_datetime

    belongs_to :order, HllConditionalActions.VipShop.Order
    belongs_to :server, HllConditionalActions.Servers.Server

    timestamps(type: :utc_datetime)
  end
end
