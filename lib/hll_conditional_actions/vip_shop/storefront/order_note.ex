defmodule HllConditionalActions.VipShop.Storefront.OrderNote do
  @moduledoc """
  The message a buyer leaves at checkout for the player who gets the VIP,
  shown to them in the game once the VIP is delivered (see
  `HllConditionalActions.Workers.DeliverGiftMessage`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_length 80

  schema "vip_order_notes" do
    field :message, :string
    field :delivered_at, :utc_datetime
    field :delivered_server, :string

    belongs_to :order, HllConditionalActions.VipShop.Order

    timestamps(type: :utc_datetime)
  end

  @doc "The longest message allowed."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:message])
    |> update_change(:message, &String.trim/1)
    |> validate_required([:message])
    |> validate_length(:message, max: @max_length)
  end
end
