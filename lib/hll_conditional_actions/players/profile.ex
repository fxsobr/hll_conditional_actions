defmodule HllConditionalActions.Players.Profile do
  @moduledoc """
  What CRCON knows about a player, kept locally: the summary of its
  persistent profile (sessions, playtime, penalties, flags, first and last
  seen) plus the last level and clan tag seen live, and the servers the
  player was seen on.

  Refreshed from CRCON's player history, from the live player list and
  whenever the player's page is opened (see `HllConditionalActions.Players`).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "player_profiles" do
    field :player_id, :string
    field :name, :string
    field :server_ids, {:array, :integer}, default: []
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :sessions, :integer
    field :playtime_seconds, :integer
    field :penalties, :integer, default: 0
    field :penalty_counts, :map, default: %{}
    field :flags, {:array, :map}, default: []
    field :level, :integer
    field :clan_tag, :string
    field :synced_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
