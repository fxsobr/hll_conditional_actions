defmodule HllConditionalActions.Balance.Settings do
  @moduledoc """
  How the team balance works on one server. A server without a row uses the
  defaults.

    * `trigger_gap` - the gap between the teams' average ratings, in points,
      from which a match counts as unbalanced
    * `max_moves` - the most players one balance may move
    * `max_count_gap` - how many more players one team may end up with
    * `partner_matches` - how many matches in the same squad make two
      players a group that is never split
    * `webhook_id` - where each plan is posted on Discord, if anywhere
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "balance_settings" do
    belongs_to :server, HllConditionalActions.Servers.Server
    belongs_to :webhook, HllConditionalActions.Discord.Webhook

    field :trigger_gap, :integer, default: 15
    field :max_moves, :integer, default: 12
    field :max_count_gap, :integer, default: 2
    field :partner_matches, :integer, default: 3

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:trigger_gap, :max_moves, :max_count_gap, :partner_matches, :webhook_id])
    |> validate_required([:trigger_gap, :max_moves, :max_count_gap, :partner_matches])
    |> validate_number(:trigger_gap, greater_than_or_equal_to: 5, less_than_or_equal_to: 200)
    |> validate_number(:max_moves, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> validate_number(:max_count_gap, greater_than_or_equal_to: 0, less_than_or_equal_to: 6)
    |> validate_number(:partner_matches, greater_than_or_equal_to: 2, less_than_or_equal_to: 20)
    |> foreign_key_constraint(:webhook_id)
  end
end
