defmodule HllConditionalActions.Repo.Migrations.CommunityFidelity do
  use Ecto.Migration

  def change do
    # A combined season can rank by points per match instead of the total.
    alter table(:seasons) do
      add :per_match, :boolean, null: false, default: false
    end

    # Which side each player played their season matches on.
    alter table(:season_scores) do
      add :allies_matches, :integer, null: false, default: 0
      add :axis_matches, :integer, null: false, default: 0
    end

    # The standings at the end of each day, so the page can say who went up
    # or down over the last week.
    create table(:season_rank_snapshots) do
      add :season_id, references(:seasons, on_delete: :delete_all), null: false
      add :day, :date, null: false
      add :ranks, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:season_rank_snapshots, [:season_id, :day])
  end
end
