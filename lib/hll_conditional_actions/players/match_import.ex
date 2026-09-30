defmodule HllConditionalActions.Players.MatchImport do
  @moduledoc """
  A finished match of a server whose player lines were already read into
  `HllConditionalActions.Players.MatchStat`, so it is never read twice.
  """

  use Ecto.Schema

  schema "player_match_imports" do
    belongs_to :server, HllConditionalActions.Servers.Server
    field :match_id, :string
    field :players, :integer, default: 0
    field :ended_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
