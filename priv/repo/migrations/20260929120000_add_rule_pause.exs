defmodule HllConditionalActions.Repo.Migrations.AddRulePause do
  use Ecto.Migration

  # A temporary pause ("snooze"): the rule stays enabled but the engine skips
  # it until `paused_until` has passed. No job resumes it - the engine simply
  # compares the time on every event.
  def change do
    alter table(:rules) do
      add :paused_until, :utc_datetime
      add :pause_reason, :string
    end
  end
end
