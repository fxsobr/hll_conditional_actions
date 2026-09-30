defmodule HllConditionalActions.Features.ShopKey do
  @moduledoc """
  Whether a server's CRCON key can do what the VIP shop needs, for the
  marketplace's warning ("A chave do CRCON precisa ler a lista de VIPs").

  The answer is kept where the app already keeps it: the server's
  `known_permissions` and `permissions_checked_at`. When that is missing or
  older than six hours, `refresh/1` asks CRCON once more with
  `get_own_user_permissions` - a read, nothing changes on the game server -
  and stores the result without broadcasting a server update, so the
  server's log stream is not restarted for it.

  An unknown key (never checked, or CRCON did not answer) is not reported
  as missing anything.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.Permissions
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  @max_age_seconds 6 * 60 * 60

  @doc """
  The shop permissions the key was last seen to lack.
  """
  @spec missing(Server.t()) :: [String.t()]
  def missing(%Server{known_permissions: known}), do: Permissions.missing_for_shop(known || [])

  @doc """
  Whether the stored permissions are too old (or were never read).

      iex> alias HllConditionalActions.Features.ShopKey
      iex> ShopKey.stale?(%HllConditionalActions.Servers.Server{permissions_checked_at: nil})
      true
  """
  @spec stale?(Server.t(), DateTime.t()) :: boolean()
  def stale?(server, now \\ DateTime.utc_now())
  def stale?(%Server{permissions_checked_at: nil}, _now), do: true

  def stale?(%Server{permissions_checked_at: at}, now),
    do: DateTime.diff(now, at, :second) > @max_age_seconds

  @doc """
  Reads the key's permissions from CRCON and stores them on the server.
  Returns the server with the new permissions.
  """
  @spec refresh(Server.t()) :: {:ok, Server.t()} | {:error, term()}
  def refresh(%Server{} = server) do
    case Crcon.get_own_user_permissions(server) do
      {:ok, payload} when is_map(payload) ->
        granted = Permissions.review(payload).granted
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Server
        |> where([s], s.id == ^server.id)
        |> Repo.update_all(set: [known_permissions: granted, permissions_checked_at: now])

        {:ok, %{server | known_permissions: granted, permissions_checked_at: now}}

      {:ok, _unexpected} ->
        {:error, :unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
