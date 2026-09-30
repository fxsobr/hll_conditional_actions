defmodule HllConditionalActions.Features.Copy do
  @moduledoc """
  Copies the set of marketplace modules of one server onto another, so a
  new server can be set up like an existing one in one step.

  Only the installations are copied - never rules, tickets, achievements or
  any other data. Every module the source runs and the target lacks is
  installed. Modules the target runs and the source does not are kept,
  unless the caller asks for them to be removed too (`remove_extras: true`);
  removing only hides a module, so its data stays either way.

  The target's processes restart once, with the whole new set, instead of
  once per module.
  """

  import Ecto.Query

  alias HllConditionalActions.Features
  alias HllConditionalActions.Features.Installation
  alias HllConditionalActions.Repo

  @type plan :: %{install: [Features.feature()], extra: [Features.feature()]}

  @doc """
  What copying `source_id`'s modules onto `target_id` would change: the
  modules to install, and the extras only the target has. Both lists follow
  the order of the marketplace.
  """
  @spec plan(term(), term()) :: plan()
  def plan(source_id, target_id) do
    source = Features.installed(source_id)
    target = Features.installed(target_id)

    %{
      install:
        Enum.filter(
          Features.catalog(),
          &(MapSet.member?(source, &1) and not MapSet.member?(target, &1))
        ),
      extra:
        Enum.filter(
          Features.catalog(),
          &(MapSet.member?(target, &1) and not MapSet.member?(source, &1))
        )
    }
  end

  @doc """
  Makes `target_id` run the modules `source_id` runs.

  Options:

    * `:remove_extras` - also remove the modules only the target has
      (default `false`).
    * `:actor` - who did it, stored on the new installations.

  Returns what changed. Copying a server onto itself is refused.
  """
  @spec copy(term(), term(), keyword()) ::
          {:ok, %{installed: [Features.feature()], removed: [Features.feature()]}}
          | {:error, :same_server}
  def copy(source_id, target_id, opts \\ [])

  def copy(same, same, _opts), do: {:error, :same_server}

  def copy(source_id, target_id, opts) do
    %{install: install, extra: extra} = plan(source_id, target_id)
    remove = if Keyword.get(opts, :remove_extras, false), do: extra, else: []

    if install != [] or remove != [] do
      {:ok, _changes} =
        Repo.transaction(fn ->
          insert(target_id, install, Keyword.get(opts, :actor))
          delete(target_id, remove)
        end)

      Features.broadcast(target_id)
    end

    {:ok, %{installed: install, removed: remove}}
  end

  defp insert(_target_id, [], _actor), do: :ok

  defp insert(target_id, features, actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(features, fn feature ->
        %{
          server_id: target_id,
          feature: to_string(feature),
          installed_by: actor,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Installation, rows,
      on_conflict: :nothing,
      conflict_target: [:server_id, :feature]
    )
  end

  defp delete(_target_id, []), do: :ok

  defp delete(target_id, features) do
    names = Enum.map(features, &to_string/1)

    Installation
    |> where([i], i.server_id == ^target_id and i.feature in ^names)
    |> Repo.delete_all()
  end
end
