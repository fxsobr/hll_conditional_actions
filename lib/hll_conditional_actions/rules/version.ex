defmodule HllConditionalActions.Rules.Version do
  @moduledoc """
  One entry in a rule's change history: who touched it, when, and what moved.

  A rule can kick and ban people, so "who wrote this, and when did it change"
  needs an answer that outlives the rule. The row therefore keeps the rule's
  name and the acting user's name as plain strings alongside the foreign
  keys: deleting either leaves the history readable instead of turning it
  into a list of nulls.

  `changes` holds only the fields that actually moved, as
  `%{"field" => %{"from" => …, "to" => …}}`, so the history reads as a diff
  rather than as a snapshot nobody can compare.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Rules.Rule

  @type t :: %__MODULE__{}

  @actions [:created, :updated, :enabled, :disabled, :duplicated, :deleted, :imported]

  schema "rule_versions" do
    field :rule_name, :string
    field :user_name, :string
    field :action, Ecto.Enum, values: @actions
    field :changes, :map, default: %{}

    belongs_to :rule, Rule
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Every action a version entry can record.
  """
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> cast(attrs, [:rule_id, :rule_name, :user_id, :user_name, :action, :changes])
    |> validate_required([:rule_name, :action])
    # A rule deleted between the check and the insert must not raise into the
    # caller: recording is best effort by design.
    |> foreign_key_constraint(:rule_id)
    |> foreign_key_constraint(:user_id)
  end
end
