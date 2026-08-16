defmodule HllConditionalActions.Rules.Execution do
  @moduledoc """
  An audit record of a rule firing for a player.

  This table is both the audit log and the state behind rate limiting: the
  cooldown check reads the newest row for a `{rule, player}` pair, and the
  per-player cap counts rows inside a 24 hour window. Keeping it in Postgres
  rather than Redis means the history survives restarts and can be browsed in
  the UI.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{}

  schema "rule_executions" do
    field :player_id, :string
    field :player_name, :string
    field :trigger_event, :string

    field :status, Ecto.Enum,
      values: [:executed, :partial, :failed, :simulated],
      default: :executed

    field :results, {:array, :map}, default: []
    field :error, :string
    field :executed_at, :utc_datetime_usec

    belongs_to :rule, Rule
    belongs_to :server, Server

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a changeset for an execution record.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :rule_id,
      :server_id,
      :player_id,
      :player_name,
      :trigger_event,
      :status,
      :results,
      :error,
      :executed_at
    ])
    |> validate_required([:rule_id, :server_id, :trigger_event, :status])
    |> put_default_executed_at()
  end

  defp put_default_executed_at(changeset) do
    case get_field(changeset, :executed_at) do
      nil -> put_change(changeset, :executed_at, DateTime.utc_now())
      _set -> changeset
    end
  end
end
