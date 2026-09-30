defmodule HllConditionalActions.Rules.SimulatorTest do
  @moduledoc """
  An event composed in the event simulator and saved to be run again: the
  sample the evaluator reads, stored as an Erlang term like
  `HllConditionalActions.Engine.SavedEvent`, plus a name.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{}

  schema "simulator_tests" do
    field :name, :string
    field :trigger, :string
    field :payload, :binary
    field :created_by, :string
    field :sample, :map, virtual: true

    belongs_to :server, Server

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(test, attrs) do
    test
    |> cast(attrs, [:name, :trigger, :payload, :created_by, :server_id])
    |> validate_required([:name, :trigger, :payload, :server_id])
    |> validate_length(:name, max: 120)
    |> foreign_key_constraint(:server_id)
  end
end
