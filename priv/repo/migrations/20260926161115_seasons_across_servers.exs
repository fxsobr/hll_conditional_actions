defmodule HllConditionalActions.Repo.Migrations.SeasonsAcrossServers do
  use Ecto.Migration

  # A season can run on one server or across several of the same game: the
  # servers move to a join table, the season keeps the game they share, and
  # `rating` holds the formula of a rating season.
  def up do
    create table(:season_servers, primary_key: false) do
      add :season_id, references(:seasons, on_delete: :delete_all), null: false, primary_key: true
      add :server_id, references(:servers, on_delete: :delete_all), null: false, primary_key: true
    end

    create index(:season_servers, [:server_id])

    # A rating drifts back to the start while its player stays away.
    alter table(:season_scores) do
      add :last_match_at, :utc_datetime
      add :decayed_at, :utc_datetime
    end

    execute "UPDATE season_scores SET last_match_at = updated_at"

    alter table(:seasons) do
      add :game, :string, null: false, default: "hll"
      add :rating, :map, null: false, default: %{}
    end

    execute """
    INSERT INTO season_servers (season_id, server_id)
    SELECT id, server_id FROM seasons WHERE server_id IS NOT NULL
    """

    execute """
    UPDATE seasons SET game = servers.game
    FROM servers WHERE servers.id = seasons.server_id
    """

    alter table(:seasons) do
      remove :server_id
    end
  end

  def down do
    alter table(:seasons) do
      add :server_id, references(:servers, on_delete: :delete_all)
    end

    execute """
    UPDATE seasons SET server_id = (
      SELECT min(server_id) FROM season_servers WHERE season_id = seasons.id
    )
    """

    alter table(:seasons) do
      remove :game
      remove :rating
    end

    alter table(:season_scores) do
      remove :last_match_at
      remove :decayed_at
    end

    drop table(:season_servers)
  end
end
