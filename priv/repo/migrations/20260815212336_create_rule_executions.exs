defmodule HllConditionalActions.Repo.Migrations.CreateRuleExecutions do
  use Ecto.Migration

  def change do
    create table(:rule_executions) do
      add :rule_id, references(:rules, on_delete: :delete_all), null: false
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :player_id, :string
      add :player_name, :string
      add :trigger_event, :string, null: false
      add :status, :string, null: false, default: "executed"
      add :results, :jsonb, null: false, default: "[]"
      add :error, :text
      add :executed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Cooldown and per-player cap lookups: newest execution of a rule for a
    # player, and counts within a window.
    create index(:rule_executions, [:rule_id, :player_id, "executed_at DESC"])
    # The audit log UI, filtered by server and paged by recency.
    create index(:rule_executions, [:server_id, "executed_at DESC"])
  end
end
