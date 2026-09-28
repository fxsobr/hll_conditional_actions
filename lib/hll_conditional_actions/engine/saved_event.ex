defmodule HllConditionalActions.Engine.SavedEvent do
  @moduledoc """
  One real event kept on disk: the same sample `HllConditionalActions.Engine.Samples`
  holds in memory, serialized, plus the columns it is looked up by.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "saved_events" do
    field :trigger, :string
    field :player_id, :string
    field :player_name, :string
    field :payload, :binary
    field :occurred_at, :utc_datetime_usec
    field :sample, :map, virtual: true

    belongs_to :server, HllConditionalActions.Servers.Server

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
