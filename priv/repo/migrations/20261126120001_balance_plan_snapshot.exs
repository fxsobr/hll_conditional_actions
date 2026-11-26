defmodule HllConditionalActions.Repo.Migrations.BalancePlanSnapshot do
  use Ecto.Migration

  # What the balance saw when it planned: every player with the rating it
  # counted then, and each team's totals - so the plan can be replayed with
  # other settings later, and judged against what the ratings said before
  # they learned from the match.
  def change do
    alter table(:balance_plans) do
      add :roster, {:array, :map}, null: false, default: []
      add :teams, :map, null: false, default: %{}
    end
  end
end
