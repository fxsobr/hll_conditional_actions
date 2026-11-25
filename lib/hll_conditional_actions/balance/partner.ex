defmodule HllConditionalActions.Balance.Partner do
  @moduledoc """
  Two players who finished matches in the same squad, and how many. The
  balance never splits players who did it often: they are a group.
  `player_a` is always the smaller ID.
  """

  use Ecto.Schema

  @primary_key false
  schema "balance_partners" do
    field :player_a, :string, primary_key: true
    field :player_b, :string, primary_key: true
    field :matches, :integer, default: 1
    field :last_at, :utc_datetime
  end
end
