defmodule HllConditionalActions.Servers do
  @moduledoc """
  Manages the CRCON deployments this application drives.

  Any change here is broadcast on `"servers"` so
  `HllConditionalActions.Runtime` can start, restart or stop the processes that
  talk to a server without the caller having to know they exist.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  @topic "servers"

  @doc """
  Subscribes the calling process to server lifecycle messages:
  `{:server_created | :server_updated | :server_deleted, server}`.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  @doc """
  Lists every server, newest first.
  """
  @spec list_servers() :: [Server.t()]
  def list_servers do
    Repo.all(from s in Server, order_by: [asc: s.name])
  end

  @doc """
  Lists servers the engine should connect to.
  """
  @spec list_enabled_servers() :: [Server.t()]
  def list_enabled_servers do
    Repo.all(from s in Server, where: s.enabled == true, order_by: [asc: s.name])
  end

  @doc """
  Lists enabled servers running a given game.
  """
  @spec list_enabled_servers(atom()) :: [Server.t()]
  def list_enabled_servers(game) do
    Repo.all(
      from s in Server, where: s.enabled == true and s.game == ^game, order_by: [asc: s.name]
    )
  end

  @doc """
  Lists the servers a user may see.

  A user with no server assignment sees them all; see
  `HllConditionalActions.Accounts.server_scope/1`.
  """
  @spec list_servers_for(map() | nil) :: [Server.t()]
  def list_servers_for(user) do
    case HllConditionalActions.Accounts.server_scope(user) do
      :all -> list_servers()
      ids -> Repo.all(from s in Server, where: s.id in ^ids, order_by: [asc: s.name])
    end
  end

  @doc """
  Fetches a server, raising if it does not exist.
  """
  @spec get_server!(term()) :: Server.t()
  def get_server!(id), do: Repo.get!(Server, id)

  @doc """
  Fetches a server.
  """
  @spec fetch_server(term()) :: {:ok, Server.t()} | :error
  def fetch_server(id) do
    case Repo.get(Server, id) do
      nil -> :error
      server -> {:ok, server}
    end
  end

  @doc """
  Creates a server.
  """
  @spec create_server(map()) :: {:ok, Server.t()} | {:error, Ecto.Changeset.t()}
  def create_server(attrs) do
    %Server{}
    |> Server.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:server_created)
  end

  @doc """
  Updates a server.
  """
  @spec update_server(Server.t(), map()) :: {:ok, Server.t()} | {:error, Ecto.Changeset.t()}
  def update_server(%Server{} = server, attrs) do
    server
    |> Server.changeset(attrs)
    |> Repo.update()
    |> broadcast(:server_updated)
  end

  @doc """
  Deletes a server along with its rules and execution history.
  """
  @spec delete_server(Server.t()) :: {:ok, Server.t()} | {:error, Ecto.Changeset.t()}
  def delete_server(%Server{} = server) do
    server
    |> Repo.delete()
    |> broadcast(:server_deleted)
  end

  @doc """
  Builds a changeset for a server form.
  """
  @spec change_server(Server.t(), map()) :: Ecto.Changeset.t()
  def change_server(%Server{} = server, attrs \\ %{}) do
    Server.changeset(server, attrs)
  end

  @doc """
  Verifies that CRCON answers with the configured credentials.

  Takes either a persisted server or the raw attributes of an unsaved form, so
  the UI can offer a "test connection" button before the first save.
  """
  @spec check_connection(Server.t() | map()) ::
          {:ok, map()} | {:error, Crcon.Error.t() | :incomplete}
  def check_connection(%Server{} = server), do: Crcon.check_connection(server)

  def check_connection(attrs) when is_map(attrs) do
    base_url = attrs |> Map.get("base_url", attrs[:base_url]) |> to_string() |> String.trim()
    api_key = attrs |> Map.get("api_key", attrs[:api_key]) |> to_string() |> String.trim()

    if base_url == "" or api_key == "" do
      {:error, :incomplete}
    else
      Crcon.check_connection(%{base_url: String.trim_trailing(base_url, "/"), api_key: api_key})
    end
  end

  @doc """
  Remembers what a key was last seen to be allowed to do.

  Called after a successful connection test so the rules list can warn that
  an action will never work on this server, without a CRCON round trip of its
  own. Best effort: a server that saved must not fail because this did.
  """
  @spec remember_permissions(Server.t(), [String.t()]) :: Server.t()
  def remember_permissions(%Server{} = server, granted) when is_list(granted) do
    case update_server(server, %{
           known_permissions: granted,
           permissions_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, updated} -> updated
      {:error, _changeset} -> server
    end
  end

  defp broadcast({:ok, server} = result, event) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {event, server})
    result
  end

  defp broadcast(result, _event), do: result
end
