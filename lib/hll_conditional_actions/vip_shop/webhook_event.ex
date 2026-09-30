defmodule HllConditionalActions.VipShop.WebhookEvent do
  @moduledoc """
  One notification a payment provider sent: the event it named, the order it
  was about when one was found, and whether it was accepted.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "vip_webhook_events" do
    field :provider, :string
    field :event, :string
    field :order_id, :integer
    field :ok, :boolean, default: true
    field :error, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
