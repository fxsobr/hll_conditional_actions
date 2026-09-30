defmodule HllConditionalActions.Progression.SeasonRankSnapshot do
  @moduledoc """
  A season's standings at the end of one day: each player's rank, by player
  ID. Written whenever a match adds to the season, so the page can tell who
  went up or down over the last week.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "season_rank_snapshots" do
    belongs_to :season, HllConditionalActions.Progression.Season
    field :day, :date
    field :ranks, :map, default: %{}

    timestamps(type: :utc_datetime)
  end
end
