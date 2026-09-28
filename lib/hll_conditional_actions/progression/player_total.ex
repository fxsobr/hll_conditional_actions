defmodule HllConditionalActions.Progression.PlayerTotal do
  @moduledoc """
  A player's running totals on one server, added to at every match end.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "player_totals" do
    belongs_to :server, HllConditionalActions.Servers.Server
    field :player_id, :string
    field :player_name, :string
    field :matches, :integer, default: 0
    field :kills, :integer, default: 0
    field :deaths, :integer, default: 0
    field :combat, :integer, default: 0
    field :offense, :integer, default: 0
    field :defense, :integer, default: 0
    field :support, :integer, default: 0
    field :vehicles_destroyed, :integer, default: 0
    field :playtime_seconds, :integer, default: 0
    field :commander_matches, :integer, default: 0
    field :leader_matches, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
