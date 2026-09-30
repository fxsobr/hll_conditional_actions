defmodule HllConditionalActions.Repo.Migrations.CreatePlayerDirectory do
  use Ecto.Migration

  # The players page's own memory of what CRCON knows about each player.
  #
  # `player_profiles` mirrors the summary of CRCON's persistent profile
  # (sessions, playtime, penalties, flags, first and last seen), refreshed
  # from its player history, from the live player list and whenever a
  # player's page is opened - so the list can search, filter, count and sort
  # thousands of players without one CRCON call per row.
  #
  # `player_match_stats` keeps each player's line of every finished match,
  # read once from CRCON's match history (`get_map_scoreboard`); a match is
  # immutable once over, so `player_match_imports` remembers which ones were
  # read and none is fetched twice.
  def change do
    create table(:player_profiles) do
      add :player_id, :string, null: false
      add :name, :string
      add :server_ids, {:array, :integer}, null: false, default: []
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :sessions, :integer
      add :playtime_seconds, :integer
      add :penalties, :integer, null: false, default: 0
      add :penalty_counts, :map, null: false, default: %{}
      add :flags, {:array, :map}, null: false, default: []
      add :level, :integer
      add :clan_tag, :string
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:player_profiles, [:player_id])
    create index(:player_profiles, [:last_seen_at])
    create index(:player_profiles, [:server_ids], using: :gin)

    create table(:player_match_stats) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :match_id, :string, null: false
      add :player_id, :string, null: false
      add :player_name, :string
      add :map, :string
      add :mode, :string
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :team, :string
      add :role, :string
      add :level, :integer
      add :kills, :integer, null: false, default: 0
      add :deaths, :integer, null: false, default: 0
      add :team_kills, :integer, null: false, default: 0
      add :combat, :integer, null: false, default: 0
      add :offense, :integer, null: false, default: 0
      add :defense, :integer, null: false, default: 0
      add :support, :integer, null: false, default: 0
      add :vehicles_destroyed, :integer, null: false, default: 0
      add :playtime_seconds, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:player_match_stats, [:server_id, :match_id, :player_id])
    create index(:player_match_stats, [:player_id, :ended_at])

    create table(:player_match_imports) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :match_id, :string, null: false
      add :players, :integer, null: false, default: 0
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:player_match_imports, [:server_id, :match_id])
  end
end
