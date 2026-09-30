defmodule HllConditionalActions.LiveFeed do
  @moduledoc """
  What the live feed of a server needs beyond the log stream itself: the
  lines that came before the page opened, and which rule (or ticket) acted
  on each line.

  ## Linking a line to what it caused

  A CRCON log line has no id of its own, so `event_key/1` derives one from
  what the line says - its game time, its action, both players and its
  text. The engine stores that key in the trace of every execution a line
  triggered (`"event_key"`), which is what lets the feed put the rule that
  acted beside the line that made it act, both for lines arriving live and
  for the ones read back from `get_recent_logs`: the same line gives the
  same key whichever way it came in.

  Tickets opened from the chat are linked by player and time instead: a
  ticket keeps the chat line it came from under the stream's own id, which
  a line read back from the recent logs does not carry.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon.Client
  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Tickets.Ticket

  # How far a ticket's creation may be from the chat line that opened it:
  # the game server's clock and ours are not the same clock.
  @ticket_window_before 60
  @ticket_window_after 180

  @doc """
  A stable key for a log line, the same for the line as the stream pushed
  it and as `get_recent_logs` returns it. `nil` for a line without a game
  time (nothing to tell two of them apart).

      iex> alias HllConditionalActions.Crcon.Events
      iex> line = %{"action" => "KILL", "player_id_1" => "1", "player_id_2" => "2",
      ...>          "message" => "a -> b", "timestamp_ms" => 1_700_000_000_000}
      iex> key = HllConditionalActions.LiveFeed.event_key(Events.from_log(line))
      iex> key == HllConditionalActions.LiveFeed.event_key(Events.from_log(Map.put(line, "stream_id", "9-0")))
      true
      iex> HllConditionalActions.LiveFeed.event_key(Events.from_log(Map.delete(line, "timestamp_ms")))
      nil
  """
  @spec event_key(Event.t() | nil) :: String.t() | nil
  def event_key(%Event{raw: %{"timestamp_ms" => ms}} = event) when is_integer(ms) do
    text = event.chat_message || event.message || ""

    digest =
      {event.action, event.player_id, event.target_player_id, text}
      |> :erlang.phash2(4_294_967_296)
      |> Integer.to_string(36)

    "#{ms}-#{String.downcase(digest)}"
  end

  def event_key(_event), do: nil

  @doc """
  The key of the line that triggered an execution, when the engine stored
  one (executions of periodic rules have none).
  """
  @spec execution_event_key(Execution.t()) :: String.t() | nil
  def execution_event_key(%Execution{trace: %{"event_key" => key}}) when is_binary(key), do: key
  def execution_event_key(_execution), do: nil

  @doc """
  The last `limit` lines of a server's log, newest first, as events.

  Read from CRCON's `get_recent_logs`, which keeps the last hours of the
  game's log in memory. A key without the permission to read the logs, or a
  CRCON that does not answer, gives an error and the feed starts empty.
  """
  @spec recent_events(map(), pos_integer()) :: {:ok, [Event.t()]} | {:error, term()}
  def recent_events(server, limit) do
    case Client.request(server, "get_recent_logs", %{end: limit}, retry: false) do
      {:ok, %{"logs" => logs}} when is_list(logs) -> {:ok, to_events(logs, server, limit)}
      {:ok, logs} when is_list(logs) -> {:ok, to_events(logs, server, limit)}
      {:ok, _other} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  defp to_events(logs, server, limit) do
    logs
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Events.from_log(&1, server))
    |> Enum.sort_by(&DateTime.to_unix(&1.occurred_at, :millisecond), :desc)
    |> Enum.take(limit)
  end

  @doc """
  The executions of a server since a time (or the latest ones), newest
  first, with their rule.
  """
  @spec executions(term(), keyword()) :: [Execution.t()]
  def executions(server_id, opts \\ []) do
    Rules.list_executions(
      server_id: server_id,
      from: Keyword.get(opts, :since),
      limit: Keyword.get(opts, :limit, 60)
    )
  end

  @doc """
  What the feed shows of an execution: the rule, how it ended and, on a
  ladder, which rung it was.
  """
  @spec annotation(Execution.t(), map() | nil) :: map()
  def annotation(%Execution{} = execution, rule) do
    trace = execution.trace || %{}

    %{
      execution_id: execution.id,
      rule_id: execution.rule_id,
      rule_name: rule && rule.name,
      status: execution.status,
      step: if(is_integer(trace["step"]) and (trace["steps"] || 0) > 1, do: trace["step"]),
      action: first_action(execution.results),
      player: execution.player_name,
      occurred_at: execution.executed_at
    }
  end

  defp first_action([%{"type" => type} | _rest]) when is_binary(type), do: type
  defp first_action(_results), do: nil

  @doc """
  The tickets opened from the chat around a set of chat lines (events, or
  feed rows carrying their line's `:key`), as `%{event_key => %{id,
  player_id}}`: each ticket goes to the line of its player closest to when
  it was opened.
  """
  @spec tickets_for(term(), [Event.t() | map()]) :: %{String.t() => map()}
  def tickets_for(_server_id, []), do: %{}

  def tickets_for(server_id, events) do
    events = Enum.filter(events, &(&1.type == :player_chat and is_binary(&1.player_id)))
    chat_tickets(server_id, events)
  end

  defp chat_tickets(_server_id, []), do: %{}

  defp chat_tickets(server_id, events) do
    times = Enum.map(events, & &1.occurred_at)
    from = DateTime.add(Enum.min(times, DateTime), -@ticket_window_after, :second)
    until = DateTime.add(Enum.max(times, DateTime), @ticket_window_after, :second)
    player_ids = events |> Enum.map(& &1.player_id) |> Enum.uniq()

    from(t in Ticket,
      where:
        t.server_id == ^server_id and t.source == :chat and t.player_id in ^player_ids and
          t.inserted_at >= ^DateTime.truncate(from, :second) and
          t.inserted_at <= ^DateTime.truncate(until, :second),
      select: %{id: t.id, player_id: t.player_id, inserted_at: t.inserted_at}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, &put_ticket_line(&1, &2, events))
    |> Map.delete(nil)
  end

  defp put_ticket_line(ticket, acc, events) do
    case closest_line(ticket, events) do
      nil -> acc
      event -> Map.put(acc, line_key(event), Map.take(ticket, [:id, :player_id]))
    end
  end

  # A feed row carries its line's key; an event has it computed.
  defp line_key(%{key: key}) when is_binary(key), do: key
  defp line_key(event), do: event_key(event)

  defp closest_line(ticket, events) do
    events
    |> Enum.filter(fn event ->
      diff = DateTime.diff(ticket.inserted_at, event.occurred_at)

      event.player_id == ticket.player_id and diff >= -@ticket_window_before and
        diff <= @ticket_window_after
    end)
    |> Enum.min_by(&abs(DateTime.diff(ticket.inserted_at, &1.occurred_at)), fn -> nil end)
  end
end
