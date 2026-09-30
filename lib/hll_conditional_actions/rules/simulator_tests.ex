defmodule HllConditionalActions.Rules.SimulatorTests do
  @moduledoc """
  The events an admin saved from the event simulator ("Salvar como teste"),
  to run the same situation again after changing a rule.

  A test is only ever evaluated, never sent: the simulator judges it with
  `HllConditionalActions.Engine.Simulator`, which records and sends nothing.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Rules.SimulatorTest

  @doc "The saved tests of some servers, newest first, with their samples."
  @spec list([term()], keyword()) :: [SimulatorTest.t()]
  def list(server_ids, opts \\ []) do
    SimulatorTest
    |> where([t], t.server_id in ^server_ids)
    |> order_by([t], desc: t.inserted_at, desc: t.id)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
    |> Enum.flat_map(&decode/1)
  end

  @doc "Saves a composed sample under a name."
  @spec create(map(), String.t(), String.t() | nil) ::
          {:ok, SimulatorTest.t()} | {:error, Ecto.Changeset.t()}
  def create(sample, name, created_by \\ nil) do
    %SimulatorTest{}
    |> SimulatorTest.changeset(%{
      name: name |> to_string() |> String.trim() |> String.slice(0, 120),
      trigger: to_string(sample.trigger),
      payload: :erlang.term_to_binary(sample, [:compressed]),
      created_by: created_by,
      server_id: sample.server_id
    })
    |> Repo.insert()
  end

  @doc "Deletes a saved test of one of these servers."
  @spec delete([term()], term()) :: :ok
  def delete(server_ids, id) do
    Repo.delete_all(from t in SimulatorTest, where: t.id == ^id and t.server_id in ^server_ids)
    :ok
  end

  # A payload written by an older build may name an atom this one does not
  # know; that test is skipped rather than crashing the page.
  defp decode(%SimulatorTest{payload: payload} = test) do
    sample = :erlang.binary_to_term(payload, [:safe])
    trigger = Enum.find(Catalog.triggers(), &(to_string(&1) == test.trigger))
    [%{test | sample: %{sample | trigger: trigger}}]
  rescue
    ArgumentError -> []
  end
end
