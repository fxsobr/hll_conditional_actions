defmodule HllConditionalActions.Repo.Migrations.AddTraceToRuleExecutions do
  use Ecto.Migration

  def change do
    # What the engine saw when the rule fired: each condition with the value
    # it read and what it was compared against, the escalation rung and how
    # long the run took. It is what lets the history answer "why did this
    # fire" instead of only "what did it do". Older rows keep an empty map.
    alter table(:rule_executions) do
      add :trace, :map, null: false, default: %{}
    end
  end
end
