defmodule HllConditionalActions.Engine.Snapshot do
  @moduledoc """
  A cached view of a CRCON server's live state.

  `get_detailed_players` and `get_gamestate` are the two expensive calls in
  CRCON's API, and a busy match produces several log lines per second. Fetching
  both once and reusing the result for a short window keeps the engine from
  turning a firefight into an API flood, while still being fresh enough for
  rules that look at kill counts.

  The window is configurable:

      config :hll_conditional_actions, :snapshot_ttl_ms, 5_000
  """

  require Logger

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Servers.Server

  @type t :: %__MODULE__{
          players: %{String.t() => map()},
          gamestate: map() | nil,
          fetched_at: integer(),
          stale?: boolean()
        }

  defstruct players: %{}, gamestate: nil, fetched_at: 0, stale?: true

  @doc """
  Returns the cached snapshot when it is still fresh, otherwise fetches a new
  one from CRCON.

  A failed fetch keeps the previous snapshot and marks it stale rather than
  dropping to an empty one: evaluating against slightly old stats beats
  evaluating against nothing, and `stale?` lets callers skip rules that would
  be unsafe on old data.
  """
  @spec fetch(Server.t(), t() | nil) :: t()
  def fetch(%Server{} = server, cached \\ nil) do
    if fresh?(cached) do
      cached
    else
      refresh(server, cached)
    end
  end

  @doc """
  Forces a refresh, ignoring the cache. Used by the periodic sweep, which is
  the one caller that must not act on stale numbers.
  """
  @spec refresh(Server.t(), t() | nil) :: t()
  def refresh(%Server{} = server, cached \\ nil) do
    players = fetch_players(server)
    gamestate = fetch_gamestate(server)

    case {players, gamestate} do
      {{:ok, players}, {:ok, gamestate}} ->
        %__MODULE__{
          players: players,
          gamestate: gamestate,
          fetched_at: now(),
          stale?: false
        }

      _partial_failure ->
        keep(cached, players, gamestate)
    end
  end

  @doc """
  Whether a snapshot is still within its freshness window.
  """
  @spec fresh?(t() | nil) :: boolean()
  def fresh?(nil), do: false
  def fresh?(%__MODULE__{stale?: true}), do: false
  def fresh?(%__MODULE__{fetched_at: at}), do: now() - at < ttl_ms()

  @doc """
  Looks a player up in the snapshot.
  """
  @spec player(t() | nil, String.t() | nil) :: map() | nil
  def player(nil, _player_id), do: nil
  def player(_snapshot, nil), do: nil
  def player(%__MODULE__{players: players}, player_id), do: Map.get(players, player_id)

  @doc """
  Every player in the snapshot as `{player_id, player}` pairs.
  """
  @spec players(t() | nil) :: [{String.t(), map()}]
  def players(nil), do: []
  def players(%__MODULE__{players: players}), do: Map.to_list(players)

  defp fetch_players(server) do
    case Crcon.get_detailed_players(server) do
      {:ok, %{"players" => players}} when is_map(players) ->
        {:ok, players}

      {:ok, other} ->
        Logger.warning("[engine] unexpected get_detailed_players payload: #{inspect(other)}")
        :error

      {:error, error} ->
        Logger.warning(
          "[engine] #{server.name}: could not read players - #{Exception.message(error)}"
        )

        :error
    end
  end

  defp fetch_gamestate(server) do
    case Crcon.get_gamestate(server) do
      {:ok, gamestate} when is_map(gamestate) ->
        {:ok, gamestate}

      {:error, error} ->
        Logger.warning(
          "[engine] #{server.name}: could not read game state - #{Exception.message(error)}"
        )

        :error

      _other ->
        :error
    end
  end

  defp keep(cached, players, gamestate) do
    %__MODULE__{} = base = cached || %__MODULE__{}

    %__MODULE__{
      base
      | players: unwrap(players, base.players),
        gamestate: unwrap(gamestate, base.gamestate),
        stale?: true
    }
  end

  defp unwrap({:ok, value}, _fallback), do: value
  defp unwrap(:error, fallback), do: fallback

  defp ttl_ms, do: Application.get_env(:hll_conditional_actions, :snapshot_ttl_ms, 5_000)

  defp now, do: System.monotonic_time(:millisecond)
end
