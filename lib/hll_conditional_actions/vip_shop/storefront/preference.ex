defmodule HllConditionalActions.VipShop.Storefront.Preference do
  @moduledoc """
  The emails a shop customer wants to receive. A customer without a row
  gets every email.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "vip_customer_preferences" do
    field :expiry_reminders, :boolean, default: true
    field :receipts, :boolean, default: true

    belongs_to :customer, HllConditionalActions.VipShop.Customer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(preference, attrs), do: cast(preference, attrs, [:expiry_reminders, :receipts])
end
