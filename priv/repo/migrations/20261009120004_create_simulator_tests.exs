defmodule HllConditionalActions.Repo.Migrations.CreateSimulatorTests do
  use Ecto.Migration

  def change do
    # Events composed in the event simulator and kept to be run again later,
    # see HllConditionalActions.Rules.SimulatorTests.
    create table(:simulator_tests) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :trigger, :string, null: false
      add :payload, :binary, null: false
      add :created_by, :string

      timestamps(type: :utc_datetime)
    end

    create index(:simulator_tests, [:server_id, :inserted_at])
  end
end
