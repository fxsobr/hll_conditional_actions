defmodule HllConditionalActions.Features do
  @moduledoc """
  The marketplace: optional modules a server installs to get the pages and
  background work that go with them.

  The catalog is code - a module is only worth offering once there is code
  that honours it being off - and installations are data, one row per server
  and module. A new server starts with nothing installed, only the core
  (the server itself, its log stream and the overview).

  Installing or removing a module broadcasts `{:features_changed, server_id}`
  on `subscribe/0`, which the runtime answers by restarting that server's
  processes with the new set.
  """

  import Ecto.Query

  alias HllConditionalActions.Features.Installation
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo

  @topic "features"

  # Order is the order of the marketplace.
  @catalog [:rules, :tickets, :progression, :stats, :live_feed, :vip_shop]

  @typedoc "A module of the marketplace."
  @type feature :: :rules | :tickets | :progression | :stats | :live_feed | :vip_shop

  @doc """
  Every module the marketplace offers.

      iex> HllConditionalActions.Features.catalog()
      [:rules, :tickets, :progression, :stats, :live_feed, :vip_shop]
  """
  @spec catalog() :: [feature()]
  def catalog, do: @catalog

  @doc """
  The module a string names, or nil. Never creates atoms.

      iex> HllConditionalActions.Features.parse("tickets")
      :tickets
      iex> HllConditionalActions.Features.parse("nope")
      nil
  """
  @spec parse(String.t() | atom()) :: feature() | nil
  def parse(feature) when is_atom(feature), do: if(feature in @catalog, do: feature)
  def parse(feature) when is_binary(feature), do: Enum.find(@catalog, &(to_string(&1) == feature))

  @doc """
  Subscribes the caller to `{:features_changed, server_id}`.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  @doc """
  The modules installed on a server.
  """
  @spec installed(term()) :: MapSet.t(feature())
  def installed(nil), do: MapSet.new()

  def installed(server_id) do
    Installation
    |> where([i], i.server_id == ^server_id)
    |> select([i], i.feature)
    |> Repo.all()
    |> to_features()
  end

  @doc """
  Installed modules for several servers at once, as `%{server_id => set}`.
  Servers with nothing installed map to an empty set.
  """
  @spec installed_by_server([term()]) :: %{term() => MapSet.t(feature())}
  def installed_by_server(server_ids) do
    rows =
      Installation
      |> where([i], i.server_id in ^server_ids)
      |> select([i], {i.server_id, i.feature})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(server_ids, &{&1, to_features(Map.get(rows, &1, []))})
  end

  @doc """
  Whether a server has a module installed.
  """
  @spec installed?(term(), feature()) :: boolean()
  def installed?(nil, _feature), do: false

  def installed?(server_id, feature) do
    Installation
    |> where([i], i.server_id == ^server_id and i.feature == ^to_string(feature))
    |> Repo.exists?()
  end

  @doc """
  Installs a module on a server. Installing twice is not an error.
  """
  @spec install(term(), feature(), String.t() | nil) :: :ok | {:error, Ecto.Changeset.t()}
  def install(server_id, feature, installed_by \\ nil) when feature in @catalog do
    %Installation{}
    |> Installation.changeset(%{
      server_id: server_id,
      feature: to_string(feature),
      installed_by: installed_by
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:server_id, :feature])
    |> case do
      {:ok, _installation} -> broadcast(server_id)
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Removes a module from a server. Its data stays, so installing it again
  brings everything back.
  """
  @spec uninstall(term(), feature()) :: :ok
  def uninstall(server_id, feature) when feature in @catalog do
    Installation
    |> where([i], i.server_id == ^server_id and i.feature == ^to_string(feature))
    |> Repo.delete_all()

    broadcast(server_id)
  end

  # Public for `Features.Copy`, which changes several modules at once and
  # tells the runtime only once.
  @doc false
  def broadcast(server_id) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {:features_changed, server_id})
  end

  defp to_features(names),
    do: names |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
end
