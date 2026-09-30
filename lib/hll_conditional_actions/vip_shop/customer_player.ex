defmodule HllConditionalActions.VipShop.CustomerPlayer do
  @moduledoc """
  An in-game player a customer linked to their account, picked from CRCON's
  player history. A purchase grants VIP to one of these.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "vip_customer_players" do
    field :player_id, :string
    field :player_name, :string

    belongs_to :customer, HllConditionalActions.VipShop.Customer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:player_id, :player_name])
    |> validate_required([:player_id])
    |> validate_length(:player_id, max: 64)
    |> unique_constraint([:customer_id, :player_id])
  end
end
