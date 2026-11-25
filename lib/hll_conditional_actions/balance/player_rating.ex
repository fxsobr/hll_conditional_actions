defmodule HllConditionalActions.Balance.PlayerRating do
  @moduledoc """
  A player's balance rating: the same Elo as a rating season
  (`HllConditionalActions.Progression.Rating`), but never reset, so the
  balance still knows who is strong the day after a season starts over.
  One per player and game.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "balance_ratings" do
    field :game, :string
    field :player_id, :string
    field :player_name, :string
    field :rating, :integer, default: 1000
    field :matches, :integer, default: 0
    field :last_match_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
