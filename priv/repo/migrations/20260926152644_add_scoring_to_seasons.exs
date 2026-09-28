defmodule HllConditionalActions.Repo.Migrations.AddScoringToSeasons do
  use Ecto.Migration

  def change do
    # How a season ranks its players: the sum of one stat (what existed),
    # its average per match, a weighted mix of stats, or an Elo rating
    # driven by match results.
    alter table(:seasons) do
      add :scoring, :string, null: false, default: "sum"
      add :weights, :map, null: false, default: %{}
      # The metric only means something for sum and average.
      modify :metric, :string, null: true, from: {:string, null: false}
    end

    # `total` is the running sum an average is taken from; wins and losses
    # are what an Elo season shows beside the rating.
    alter table(:season_scores) do
      add :total, :bigint, null: false, default: 0
      add :wins, :integer, null: false, default: 0
      add :losses, :integer, null: false, default: 0
    end
  end
end
