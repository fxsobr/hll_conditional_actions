defmodule HllConditionalActions.Balance.Settings do
  @moduledoc """
  How the team balance works on one server. A server without a row uses the
  defaults.

  The decision is taken in the two minutes of preparation of a match, never
  after, and `rule` says what makes a match get a plan:

    * `"gap"` - the teams' average ratings are `trigger_gap` or more apart
    * `"previous"` - the match before had a dominant winner (at least
      `kills_ratio`% of the loser's kills or `points_ratio`% of its points)
      and at least `together`% of those winners are on one side again
    * `"both"` / `"either"` - both of those, or either

  And how the plan is made:

    * `max_moves` - the most players one plan may move
    * `max_count_gap` - how many more players one team may end up with
    * `partner_matches` - matches in one squad that make two players a group
      that is never split
    * `stack_bonus` - points the previous match's dominant winners count as
      stronger, so the plan breaks the group up
    * `cooldown_hours` - a player a plan moved is not moved again for so long
    * `webhook_id` - where each plan is posted on Discord, if anywhere
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @rules ~w(gap previous both either)

  schema "balance_settings" do
    belongs_to :server, HllConditionalActions.Servers.Server
    belongs_to :webhook, HllConditionalActions.Discord.Webhook

    field :rule, :string, default: "previous"
    field :trigger_gap, :integer, default: 35
    field :kills_ratio, :integer, default: 150
    field :points_ratio, :integer, default: 130
    field :together, :integer, default: 85
    field :stack_bonus, :integer, default: 30
    field :max_moves, :integer, default: 12
    field :max_count_gap, :integer, default: 2
    field :partner_matches, :integer, default: 3
    field :cooldown_hours, :integer, default: 3

    timestamps(type: :utc_datetime)
  end

  @doc "The rules a server can pick."
  @spec rules() :: [String.t()]
  def rules, do: @rules

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :rule,
      :trigger_gap,
      :kills_ratio,
      :points_ratio,
      :together,
      :stack_bonus,
      :max_moves,
      :max_count_gap,
      :partner_matches,
      :cooldown_hours,
      :webhook_id
    ])
    |> validate_required([
      :rule,
      :trigger_gap,
      :kills_ratio,
      :points_ratio,
      :together,
      :stack_bonus,
      :max_moves,
      :max_count_gap,
      :partner_matches,
      :cooldown_hours
    ])
    |> validate_inclusion(:rule, @rules)
    |> validate_number(:trigger_gap, greater_than_or_equal_to: 5, less_than_or_equal_to: 200)
    |> validate_number(:kills_ratio, greater_than_or_equal_to: 100, less_than_or_equal_to: 400)
    |> validate_number(:points_ratio, greater_than_or_equal_to: 100, less_than_or_equal_to: 400)
    |> validate_number(:together, greater_than_or_equal_to: 50, less_than_or_equal_to: 100)
    |> validate_number(:stack_bonus, greater_than_or_equal_to: 0, less_than_or_equal_to: 200)
    |> validate_number(:max_moves, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> validate_number(:max_count_gap, greater_than_or_equal_to: 0, less_than_or_equal_to: 6)
    |> validate_number(:partner_matches, greater_than_or_equal_to: 2, less_than_or_equal_to: 20)
    |> validate_number(:cooldown_hours, greater_than_or_equal_to: 0, less_than_or_equal_to: 48)
    |> foreign_key_constraint(:webhook_id)
  end
end
