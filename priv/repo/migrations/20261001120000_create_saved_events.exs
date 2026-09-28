defmodule HllConditionalActions.Repo.Migrations.CreateSavedEvents do
  use Ecto.Migration

  def change do
    # A rolling window of real events per server and trigger, kept so rules
    # can be tested and explained without a live server; see
    # HllConditionalActions.Engine.SavedEvents.
    create table(:saved_events) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :trigger, :string, null: false
      add :player_id, :string
      add :player_name, :string
      add :payload, :binary, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:saved_events, [:server_id, :trigger, :occurred_at])
    create index(:saved_events, [:player_id, :occurred_at])
  end
end
