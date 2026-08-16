defmodule HllConditionalActions.Repo.Migrations.CreateServers do
  use Ecto.Migration

  def change do
    create table(:servers) do
      add :name, :string, size: 120, null: false
      add :game, :string, null: false, default: "hll"
      add :base_url, :string, null: false
      # Ciphertext produced by HllConditionalActions.Vault.
      add :api_key, :binary, null: false
      add :enabled, :boolean, null: false, default: true
      add :log_stream_enabled, :boolean, null: false, default: true
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:servers, [:name])
    create index(:servers, [:game])
  end
end
