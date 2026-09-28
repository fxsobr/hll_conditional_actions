defmodule HllConditionalActions.Attention.Review do
  @moduledoc """
  An attention item somebody marked as handled. See
  `HllConditionalActions.Attention`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "attention_reviews" do
    field :key, :string
    belongs_to :user, HllConditionalActions.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(review, attrs) do
    review
    |> cast(attrs, [:key, :user_id])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
