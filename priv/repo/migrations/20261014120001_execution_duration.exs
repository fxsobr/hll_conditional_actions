defmodule HllConditionalActions.Repo.Migrations.ExecutionDuration do
  use Ecto.Migration

  # The Briefing's totals read how long each run took. Inside `trace` that
  # meant fetching every row's whole JSON, which spilled the sort to disk and
  # took most of a second per query; as a column, the index below answers
  # the totals on its own.
  def up do
    alter table(:rule_executions) do
      add :duration_ms, :integer
    end

    execute """
    UPDATE rule_executions
    SET duration_ms = round((trace->>'duration_ms')::numeric)::integer
    WHERE trace ? 'duration_ms' AND jsonb_typeof(trace->'duration_ms') = 'number'
    """

    execute """
    CREATE INDEX rule_executions_executed_at_totals_index
    ON rule_executions (executed_at)
    INCLUDE (status, player_id, duration_ms, server_id)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS rule_executions_executed_at_totals_index"

    alter table(:rule_executions) do
      remove :duration_ms
    end
  end
end
