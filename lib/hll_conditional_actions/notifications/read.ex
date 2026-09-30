defmodule HllConditionalActions.Notifications.Read do
  @moduledoc """
  A notification a user has seen. See `HllConditionalActions.Notifications`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "notification_reads" do
    field :key, :string
    belongs_to :user, HllConditionalActions.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
