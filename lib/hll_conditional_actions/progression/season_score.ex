defmodule HllConditionalActions.Progression.SeasonScore do
  @moduledoc """
  A player's standing in a season: the metric added up over the matches
  they played in it, and where they finished once it closed.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "season_scores" do
    belongs_to :season, HllConditionalActions.Progression.Season
    field :player_id, :string
    field :player_name, :string
    field :score, :integer, default: 0
    field :total, :integer, default: 0
    field :wins, :integer, default: 0
    field :losses, :integer, default: 0
    field :matches, :integer, default: 0
    field :rank, :integer
    field :rewarded_at, :utc_datetime
    field :last_match_at, :utc_datetime
    field :decayed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
