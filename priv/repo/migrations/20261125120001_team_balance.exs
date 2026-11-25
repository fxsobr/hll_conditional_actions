defmodule HllConditionalActions.Repo.Migrations.TeamBalance do
  use Ecto.Migration

  def change do
    # The squad each player ended a match in, and the match's result: what
    # the balance rating and the "who plays together" counts are learned from.
    alter table(:player_match_stats) do
      add :unit_name, :string
    end

    alter table(:player_match_imports) do
      add :allied_score, :integer
      add :axis_score, :integer
      add :balance_learned_at, :utc_datetime
    end

    create index(:player_match_imports, [:ended_at], where: "balance_learned_at IS NULL")

    # A rating that never resets, unlike a season's.
    create table(:balance_ratings) do
      add :game, :string, null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :rating, :integer, null: false, default: 1000
      add :matches, :integer, null: false, default: 0
      add :last_match_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:balance_ratings, [:game, :player_id])

    # How many matches two players finished in the same squad; `player_a` is
    # always the smaller ID.
    create table(:balance_partners, primary_key: false) do
      add :player_a, :string, null: false, primary_key: true
      add :player_b, :string, null: false, primary_key: true
      add :matches, :integer, null: false, default: 1
      add :last_at, :utc_datetime, null: false
    end

    create index(:balance_partners, [:player_b])

    create table(:balance_settings) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :trigger_gap, :integer, null: false, default: 15
      add :max_moves, :integer, null: false, default: 12
      add :max_count_gap, :integer, null: false, default: 2
      add :partner_matches, :integer, null: false, default: 3
      add :webhook_id, references(:discord_webhooks, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:balance_settings, [:server_id])

    # One per finished match: how far apart the teams were and what the
    # balance would have moved.
    create table(:balance_plans) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :map, :string
      add :ended_at, :utc_datetime, null: false
      add :status, :string, null: false
      add :players, :integer, null: false, default: 0
      add :allies_rating, :integer
      add :axis_rating, :integer
      add :gap, :integer, null: false, default: 0
      add :gap_after, :integer, null: false, default: 0
      add :strong_team, :string
      add :allied_score, :integer
      add :axis_score, :integer
      add :moves, {:array, :map}, null: false, default: []
      add :strong_ids, {:array, :string}, null: false, default: []
      add :next_allied_score, :integer
      add :next_axis_score, :integer
      add :strong_won_again, :boolean

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:balance_plans, [:server_id, :ended_at])
  end
end
