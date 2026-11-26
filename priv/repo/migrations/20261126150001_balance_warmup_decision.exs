defmodule HllConditionalActions.Repo.Migrations.BalanceWarmupDecision do
  use Ecto.Migration

  # The balance now decides in the two minutes of preparation, from the
  # analysis of the previous match, and never after. A plan row is one
  # match: written at its warmup (the decision), completed at its end (the
  # result and what the next decision will read).
  def change do
    alter table(:balance_plans) do
      modify :ended_at, :utc_datetime, null: true, from: {:utc_datetime, null: false}
      add :started_at, :utc_datetime
      # "warmup" when the teams were read in the preparation, "previous"
      # when CRCON did not report them yet and the previous match's sides,
      # swapped, stood in.
      add :source, :string
      # Which test made the plan: "gap", "previous" or "both".
      add :rule_fired, :string
      add :previous_id, references(:balance_plans, on_delete: :nilify_all)
      # The previous match's dominant winners found together in this warmup.
      add :stack_ids, {:array, :string}, null: false, default: []
      add :stack_side, :string
      add :stack_together, :integer
      # At the end: the roster as it finished, the winners, and how much the
      # winner out-did the loser (% of the loser's kills and points).
      add :end_roster, {:array, :map}, null: false, default: []
      add :winner_ids, {:array, :string}, null: false, default: []
      add :kills_ratio, :integer
      add :points_ratio, :integer
    end

    create index(:balance_plans, [:server_id, :started_at])

    alter table(:balance_settings) do
      # 35 on the balance rating's scale is where the stronger side starts
      # to win most matches; 15 marked nearly every one.
      modify :trigger_gap, :integer, default: 35, from: {:integer, default: 15}
      # When a match gets a plan: "gap", "previous", "both" or "either".
      add :rule, :string, null: false, default: "previous"
      add :kills_ratio, :integer, null: false, default: 150
      add :points_ratio, :integer, null: false, default: 130
      add :together, :integer, null: false, default: 85
      add :stack_bonus, :integer, null: false, default: 30
      # A player moved by a plan is not moved again for this long.
      add :cooldown_hours, :integer, null: false, default: 3
    end
  end
end
