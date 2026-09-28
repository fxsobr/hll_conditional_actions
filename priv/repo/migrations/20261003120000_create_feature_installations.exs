defmodule HllConditionalActions.Repo.Migrations.CreateFeatureInstallations do
  use Ecto.Migration

  # Modules a server has installed from the marketplace. A server starts with
  # none, but every server that existed before the marketplace keeps every
  # module it already had, so an upgrade takes nothing away.
  @existing_modules ~w(rules tickets progression stats live_feed)

  def up do
    create table(:feature_installations) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :feature, :string, null: false
      add :installed_by, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feature_installations, [:server_id, :feature])

    for feature <- @existing_modules do
      execute("""
      INSERT INTO feature_installations (server_id, feature, inserted_at, updated_at)
      SELECT id, '#{feature}', now(), now() FROM servers
      """)
    end
  end

  def down do
    drop table(:feature_installations)
  end
end
