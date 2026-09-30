defmodule HllConditionalActions.Players.MatchStat do
  @moduledoc """
  One player's line of one finished match, as CRCON's match history
  (`get_map_scoreboard`) recorded it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "player_match_stats" do
    belongs_to :server, HllConditionalActions.Servers.Server
    field :match_id, :string
    field :player_id, :string
    field :player_name, :string
    field :map, :string
    field :mode, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :team, :string
    field :role, :string
    field :level, :integer
    field :kills, :integer, default: 0
    field :deaths, :integer, default: 0
    field :team_kills, :integer, default: 0
    field :combat, :integer, default: 0
    field :offense, :integer, default: 0
    field :defense, :integer, default: 0
    field :support, :integer, default: 0
    field :vehicles_destroyed, :integer, default: 0
    field :playtime_seconds, :integer, default: 0

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
