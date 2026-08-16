defmodule HllConditionalActions.Repo.Migrations.CreateRules do
  use Ecto.Migration

  def change do
    create table(:rules) do
      add :name, :string, size: 120, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 0
      add :game, :string, null: false, default: "hll"
      add :trigger_event, :string, null: false
      add :trigger_interval_seconds, :integer, null: false, default: 60
      add :logical_operator, :string, null: false, default: "and"
      add :cooldown_seconds, :integer, null: false, default: 0
      add :max_executions_per_player, :integer, null: false, default: 0
      # Embedded schemas: a rule's conditions and actions are only ever read
      # and written as a whole, so they live with the rule instead of in their
      # own tables.
      add :conditions, :jsonb, null: false, default: "[]"
      add :actions, :jsonb, null: false, default: "[]"

      # Null means "every enabled server running this game".
      add :server_id, references(:servers, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:rules, [:server_id])
    # The engine loads rules by game and trigger on every event.
    create index(:rules, [:game, :trigger_event, :enabled])
  end
end
