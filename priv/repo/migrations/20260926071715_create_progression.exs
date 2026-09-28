defmodule HllConditionalActions.Repo.Migrations.CreateProgression do
  use Ecto.Migration

  def change do
    # What each player has done on a server over every match recorded, added
    # to at the end of each match. Career achievements read these.
    create table(:player_totals) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :matches, :integer, null: false, default: 0
      add :kills, :integer, null: false, default: 0
      add :deaths, :integer, null: false, default: 0
      add :combat, :integer, null: false, default: 0
      add :offense, :integer, null: false, default: 0
      add :defense, :integer, null: false, default: 0
      add :support, :integer, null: false, default: 0
      add :vehicles_destroyed, :integer, null: false, default: 0
      add :playtime_seconds, :integer, null: false, default: 0
      add :commander_matches, :integer, null: false, default: 0
      add :leader_matches, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:player_totals, [:server_id, :player_id])

    # An achievement: reach `threshold` in `metric`, either within one match
    # or over a whole career, and get the reward.
    create table(:achievements) do
      add :name, :string, null: false
      add :description, :text
      add :icon, :string, null: false, default: "hero-trophy"
      add :tier, :string, null: false, default: "bronze"
      add :scope, :string, null: false, default: "match"
      add :metric, :string, null: false
      add :threshold, :integer, null: false
      add :reward_vip_hours, :integer, null: false, default: 0
      add :reward_flag, :string
      add :announce, :boolean, null: false, default: true
      add :simulation, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:player_achievements) do
      add :achievement_id, references(:achievements, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :nilify_all)
      add :player_id, :string, null: false
      add :player_name, :string
      add :value, :integer
      add :simulated, :boolean, null: false, default: false
      add :unlocked_at, :utc_datetime, null: false
    end

    create unique_index(:player_achievements, [:achievement_id, :player_id])
    create index(:player_achievements, [:player_id])

    # A season: a leaderboard over a stretch of time on one server, whose
    # top players are rewarded when it ends.
    create table(:seasons) do
      add :name, :string, null: false
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :metric, :string, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :duration_days, :integer, null: false
      add :winners_count, :integer, null: false, default: 3
      add :min_matches, :integer, null: false, default: 3
      add :reward_vip_hours, :integer, null: false, default: 168
      add :auto_renew, :boolean, null: false, default: true
      add :status, :string, null: false, default: "active"
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:seasons, [:server_id, :status])

    create table(:season_scores) do
      add :season_id, references(:seasons, on_delete: :delete_all), null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :score, :integer, null: false, default: 0
      add :matches, :integer, null: false, default: 0
      add :rank, :integer
      add :rewarded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:season_scores, [:season_id, :player_id])
  end
end
