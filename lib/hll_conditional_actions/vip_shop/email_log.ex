defmodule HllConditionalActions.VipShop.EmailLog do
  @moduledoc """
  One email the shop tried to send: which template, to whom, whether the
  service took it and how long it took.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "vip_email_log" do
    field :template, :string
    field :to, :string
    field :ok, :boolean, default: true
    field :error, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
