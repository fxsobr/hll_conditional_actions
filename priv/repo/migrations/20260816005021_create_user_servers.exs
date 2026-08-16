defmodule HllConditionalActions.Repo.Migrations.CreateUserServers do
  use Ecto.Migration

  def change do
    # Which servers a user may see and act on. No rows for a user means no
    # restriction: they reach every server, which keeps single-community
    # installs from having to assign anything.
    create table(:user_servers, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :delete_all), null: false
    end

    create unique_index(:user_servers, [:user_id, :server_id])
    create index(:user_servers, [:server_id])
  end
end
