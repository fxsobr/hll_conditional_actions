defmodule HllConditionalActions.Repo.Migrations.AddEscalationToRules do
  use Ecto.Migration

  # An escalating rule runs one action per offence instead of all of them:
  # the first time a player trips it the first action runs, the second time
  # the second, and so on until the last. `0` keeps the old behaviour, where
  # every action runs on every firing.
  def change do
    alter table(:rules) do
      add :escalation_window_seconds, :integer, null: false, default: 0
    end
  end
end
