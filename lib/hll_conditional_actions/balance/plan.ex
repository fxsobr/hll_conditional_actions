defmodule HllConditionalActions.Balance.Plan do
  @moduledoc """
  One match as the team balance saw it, in two moments:

    * **at its warmup** - the two minutes of preparation, the only time the
      balance may act - the decision: the teams' average ratings (`roster`,
      read in the warmup, or the previous match's sides swapped when CRCON
      did not report teams yet: `source`), the previous match's dominant
      group found together again (`stack_*`, `previous_id`), which test
      fired (`rule_fired`) and the groups it would move (`moves`)
    * **at its end** - the result (`allied_score`, `axis_score`), the roster
      as it finished (`end_roster`, `teams`), the winners (`winner_ids`) and
      how much they out-did the loser (`kills_ratio`, `points_ratio`, in %
      of the loser's) - what the next warmup's decision reads

  `status`: `"balanced"` when nothing fired, `"simulated"` when a plan was
  made but - this being the simulation - not applied, `"measured"` when only
  the end was seen (the warmup was missed). `moves` holds one map per group:
  `"from"`, `"squad"` and its `"players"` (`"id"`, `"name"`, `"rating"`).

  `strong_won_again`: whether the previous match's dominant group, together
  again in this one, won it too - what the balance is meant to stop.

  Rows written before the warmup decision existed (0.5 and older) only have
  the end, in `ended_at`, `roster` and `strong_ids`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "balance_plans" do
    belongs_to :server, HllConditionalActions.Servers.Server
    belongs_to :previous, __MODULE__

    field :map, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :source, :string
    field :rule_fired, :string
    field :stack_ids, {:array, :string}, default: []
    field :stack_side, :string
    field :stack_together, :integer
    field :end_roster, {:array, :map}, default: []
    field :winner_ids, {:array, :string}, default: []
    field :kills_ratio, :integer
    field :points_ratio, :integer
    field :status, :string
    field :players, :integer, default: 0
    field :allies_rating, :integer
    field :axis_rating, :integer
    field :gap, :integer, default: 0
    field :gap_after, :integer, default: 0
    field :strong_team, :string
    field :allied_score, :integer
    field :axis_score, :integer
    field :moves, {:array, :map}, default: []
    field :strong_ids, {:array, :string}, default: []
    field :next_allied_score, :integer
    field :next_axis_score, :integer
    field :strong_won_again, :boolean
    # The players as the balance saw them: "id", "name", "team", "squad",
    # "rating" (as counted), "matches", "role", "level", "kills", "points".
    field :roster, {:array, :map}, default: []
    # Per team ("allies", "axis"): "players", "rating", "kills", "points".
    field :teams, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "How many players the plan moves."
  @spec moved(t()) :: non_neg_integer()
  def moved(%__MODULE__{moves: moves}),
    do: Enum.sum_by(moves, &length(Map.get(&1, "players", [])))
end
