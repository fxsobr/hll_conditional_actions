defmodule HllConditionalActions.Progression.PlayerAchievement do
  @moduledoc """
  An achievement a player unlocked, once and for good.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "player_achievements" do
    belongs_to :achievement, HllConditionalActions.Progression.Achievement
    belongs_to :server, HllConditionalActions.Servers.Server
    field :player_id, :string
    field :player_name, :string
    field :value, :integer
    field :simulated, :boolean, default: false
    field :unlocked_at, :utc_datetime
  end
end
