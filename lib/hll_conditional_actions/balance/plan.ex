defmodule HllConditionalActions.Balance.Plan do
  @moduledoc """
  What the balance made of one finished match: the teams' average ratings,
  the gap, and the groups it would move to close it.

  `status` is `"balanced"` when the gap was under the server's trigger and
  `"simulated"` when a plan was made but - this being the simulation - not
  applied. `moves` holds one map per group: `"from"`, `"squad"` and its
  `"players"` (`"id"`, `"name"`, `"rating"`). Since the game swaps the
  factions on the next map, a group moves "to the other team", not to a
  faction.

  `roster` and `teams` keep what the balance saw, so a plan can be replayed
  with other settings (`HllConditionalActions.Balance.Analysis`), and the
  gap stays an honest prediction: it was measured before the ratings
  learned from the match.

  `strong_ids` are the players of the stronger team; when the next match
  ends, `strong_won_again` says whether most of them, together again, won
  it - the stack the balance is meant to break up.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "balance_plans" do
    belongs_to :server, HllConditionalActions.Servers.Server

    field :map, :string
    field :ended_at, :utc_datetime
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
