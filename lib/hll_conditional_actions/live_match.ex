defmodule HllConditionalActions.LiveMatch do
  @moduledoc """
  The facts about the match being played that the cockpit shows beside the
  game state: when it started, how many players the server takes, and what
  the rules did since it started.

  CRCON's `get_public_info` carries the first two - `current_map.start` (the
  map history's start of the current map) and `max_player_count` - so they
  cost one light call, made alongside the live snapshot. When it does not
  say when the match started, the game state's `match_start` and then the
  last `MATCH START` line of the log are the next best sources
  (`started_at_from_gamestate/1`, `started_at_from/1`).
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution

  @type info :: %{started_at: DateTime.t() | nil, max_players: pos_integer() | nil}

  @doc """
  When the current match started and the server's player cap, from
  `get_public_info`. Either is `nil` when CRCON does not say.
  """
  @spec info(map()) :: {:ok, info()} | {:error, term()}
  def info(server) do
    case Crcon.get_public_info(server) do
      {:ok, info} when is_map(info) -> {:ok, parse_info(info)}
      {:ok, _other} -> {:ok, %{started_at: nil, max_players: nil}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Reads the start and the player cap out of a `get_public_info` payload.

      iex> alias HllConditionalActions.LiveMatch
      iex> LiveMatch.parse_info(%{"current_map" => %{"start" => 1_700_000_000}, "max_player_count" => 100})
      %{started_at: ~U[2023-11-14 22:13:20Z], max_players: 100}
      iex> LiveMatch.parse_info(%{})
      %{started_at: nil, max_players: nil}
  """
  @spec parse_info(map()) :: info()
  def parse_info(info) do
    %{
      started_at: info |> get_in(["current_map", "start"]) |> datetime(),
      max_players: positive(info["max_player_count"])
    }
  end

  @doc """
  The start of the match as the game state tells it (`match_start`, which
  newer CRCONs report), or nil.

      iex> HllConditionalActions.LiveMatch.started_at_from_gamestate(%{"match_start" => 1_700_000_000})
      ~U[2023-11-14 22:13:20Z]
      iex> HllConditionalActions.LiveMatch.started_at_from_gamestate(nil)
      nil
  """
  @spec started_at_from_gamestate(map() | nil) :: DateTime.t() | nil
  def started_at_from_gamestate(%{"match_start" => start}), do: datetime(start)
  def started_at_from_gamestate(_gamestate), do: nil

  @doc """
  The start of the match as the log tells it: the newest `MATCH START`
  line among `events` (newest first or not), or nil.
  """
  @spec started_at_from([map()]) :: DateTime.t() | nil
  def started_at_from(events) do
    events
    |> Enum.filter(&(&1.type == :match_start))
    |> Enum.map(& &1.occurred_at)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  What each rule did on a server since a time, as
  `%{total: n, rules: %{rule_id => %{count: n, failed: n}}}`; `failed`
  counts the executions that failed in full or in part.
  """
  @spec rule_counts(term(), DateTime.t() | nil) :: %{total: non_neg_integer(), rules: map()}
  def rule_counts(_server_id, nil), do: %{total: 0, rules: %{}}

  def rule_counts(server_id, %DateTime{} = since) do
    rules =
      from(e in Execution,
        where: e.server_id == ^server_id and e.executed_at >= ^since,
        group_by: e.rule_id,
        select:
          {e.rule_id,
           %{count: count(e.id), failed: filter(count(e.id), e.status in [:failed, :partial])}}
      )
      |> Repo.all()
      |> Map.new()

    %{total: rules |> Map.values() |> Enum.sum_by(& &1.count), rules: rules}
  end

  defp datetime(%DateTime{} = at), do: at

  # Seconds since the epoch, or milliseconds from a CRCON that sends them.
  defp datetime(value) when is_number(value) and value > 0 do
    ms = if value > 100_000_000_000, do: round(value), else: round(value * 1000)

    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> DateTime.truncate(at, :second)
      {:error, _reason} -> nil
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        at

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  defp datetime(_value), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil
end
