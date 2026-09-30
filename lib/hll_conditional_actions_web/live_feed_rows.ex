defmodule HllConditionalActionsWeb.LiveFeedRows do
  @moduledoc """
  The rows of a live feed, kept on the page's side so they can change after
  they were drawn.

  A line of the log arrives first and the rule it made act arrives a moment
  later (the engine answers after its actions ran), so the feed keeps the
  last lines it drew - a bounded buffer, newest first - and puts the rule on
  the line it belongs to when the execution comes in. The same buffer backs
  the feed's filters (everything, kills, chat, only where a rule acted): a
  filter re-streams the rows it keeps instead of asking CRCON again.

  Rows are the maps built by `HllConditionalActionsWeb.LiveComponents`
  (`event_row/3`, `execution_row/2`).
  """

  alias HllConditionalActions.LiveFeed
  alias HllConditionalActionsWeb.LiveComponents

  @filters ~w(all kills chat acted)

  @type filter :: String.t()
  @type t :: %{rows: [map()], limit: pos_integer()}

  @doc "The filters of the feed, in the order of their chips."
  @spec filters() :: [filter()]
  def filters, do: @filters

  @doc "An empty buffer keeping at most `limit` rows."
  @spec new(pos_integer()) :: t()
  def new(limit), do: %{rows: [], limit: limit}

  @doc "Puts a row on top, replacing the row with the same id if there is one."
  @spec add(t(), map()) :: t()
  def add(%{rows: rows, limit: limit} = buffer, row) do
    %{buffer | rows: Enum.take([row | Enum.reject(rows, &(&1.id == row.id))], limit)}
  end

  @doc "Replaces every row, newest first."
  @spec reset(t(), [map()]) :: t()
  def reset(%{limit: limit} = buffer, rows), do: %{buffer | rows: Enum.take(rows, limit)}

  @doc "Replaces a row already in the buffer, keeping its place."
  @spec replace(t(), map()) :: t()
  def replace(%{rows: rows} = buffer, row) do
    %{buffer | rows: Enum.map(rows, &if(&1.id == row.id, do: row, else: &1))}
  end

  @doc "The row drawn for a log line, found by the line's key."
  @spec find_by_key(t(), String.t() | nil) :: map() | nil
  def find_by_key(_buffer, nil), do: nil
  def find_by_key(%{rows: rows}, key), do: Enum.find(rows, &(Map.get(&1, :key) == key))

  @doc """
  Puts an execution on the line that triggered it, if that line is in the
  buffer. Returns `{:ok, row, buffer}` with the updated row, or `:error`.
  """
  @spec annotate(t(), String.t() | nil, map()) :: {:ok, map(), t()} | :error
  def annotate(buffer, key, annotation) do
    case find_by_key(buffer, key) do
      nil ->
        :error

      row ->
        acted =
          row.acted
          |> Enum.reject(&(&1.execution_id == annotation.execution_id))
          |> Kernel.++([annotation])

        row = %{row | acted: acted}
        {:ok, row, replace(buffer, row)}
    end
  end

  @doc "The rows a filter keeps, newest first."
  @spec visible(t(), filter()) :: [map()]
  def visible(%{rows: rows}, filter), do: Enum.filter(rows, &matches?(&1, filter))

  @doc """
  Whether a row is on screen: among the first `count` rows a filter keeps.
  A row that changed but is not on screen must not be streamed - it would
  land at the bottom of the list.
  """
  @spec shown?(t(), filter(), String.t(), pos_integer()) :: boolean()
  def shown?(buffer, filter, id, count) do
    buffer |> visible(filter) |> Enum.take(count) |> Enum.any?(&(&1.id == id))
  end

  @doc """
  Whether a row passes a filter: kills are the kill and team kill lines,
  chat the chat lines, and `acted` every line a rule (or a ticket) acted on,
  plus the rules' own lines.
  """
  @spec matches?(map(), filter()) :: boolean()
  def matches?(_row, "all"), do: true

  def matches?(%{kind: :event, type: type}, "kills"),
    do: type in [:player_kill, :player_team_kill]

  def matches?(%{kind: :event, type: type}, "chat"), do: type == :player_chat
  def matches?(%{kind: :execution}, "acted"), do: true
  def matches?(%{kind: :event} = row, "acted"), do: row.acted != [] or not is_nil(row.ticket)
  def matches?(_row, _filter), do: false

  @doc "A filter from the page's params, `all` when unknown."
  @spec parse_filter(term()) :: filter()
  def parse_filter(filter) when filter in @filters, do: filter
  def parse_filter(_filter), do: "all"

  @doc """
  The rows a feed opens with: the recent log lines with the executions they
  triggered and the tickets they opened on them, and the executions that
  came from no line (a periodic rule, a line older than the window) as rows
  of their own - everything newest first.

  Executions come with their rule preloaded (`LiveFeed.executions/2`).
  """
  @spec seed([struct()], [struct()], map(), keyword()) :: [map()]
  def seed(events, executions, tickets, opts \\ []) do
    roster = Keyword.get(opts, :roster)
    server_names = Keyword.get(opts, :server_names, %{})

    by_key =
      executions
      |> Enum.filter(&LiveFeed.execution_event_key/1)
      |> Enum.group_by(&LiveFeed.execution_event_key/1)

    event_rows =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        key = LiveFeed.event_key(event)

        acted =
          by_key
          |> Map.get(key, [])
          |> Enum.sort_by(& &1.id)
          |> Enum.map(&LiveFeed.annotation(&1, rule(&1)))

        event
        |> LiveComponents.event_row(row_id(key, "seed-#{index}"),
          roster: roster,
          server_name: Map.get(server_names, event.server_id)
        )
        |> Map.merge(%{acted: acted, ticket: Map.get(tickets, key)})
      end)

    event_rows =
      event_rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> with_session(row, Enum.drop(event_rows, index + 1)) end)

    keys = MapSet.new(event_rows, & &1.key)

    execution_rows =
      executions
      |> Enum.reject(&MapSet.member?(keys, LiveFeed.execution_event_key(&1)))
      |> Enum.map(&LiveComponents.execution_row(&1, rule(&1)))

    (event_rows ++ execution_rows)
    |> Enum.sort_by(&DateTime.to_unix(&1.occurred_at, :microsecond), :desc)
  end

  @doc """
  A leaving player's time on the server, from the line of their joining,
  when the roster did not give it (the player is gone from it by the time
  the line is drawn). `rows` are the rows before it, newest first.
  """
  @spec with_session(map(), [map()]) :: map()
  def with_session(%{kind: :event, type: :player_disconnected, details: details} = row, rows)
      when not is_map_key(details, :played) do
    joined =
      Enum.find(rows, fn other ->
        other.kind == :event and other.type == :player_connected and
          other.player_id == row.player_id and
          Map.get(other, :server_id) == Map.get(row, :server_id) and
          DateTime.compare(other.occurred_at, row.occurred_at) == :lt
      end)

    case joined && DateTime.diff(row.occurred_at, joined.occurred_at) do
      seconds when is_integer(seconds) and seconds > 0 ->
        %{row | details: Map.put(details, :played, seconds)}

      _unknown ->
        row
    end
  end

  def with_session(row, _rows), do: row

  @doc "The dom id of a log line's row: its key when it has one."
  @spec row_id(String.t() | nil, String.t()) :: String.t()
  def row_id(nil, fallback), do: "event-#{fallback}"
  def row_id(key, _fallback), do: "ev-#{key}"

  defp rule(%{rule: %HllConditionalActions.Rules.Rule{} = rule}), do: rule
  defp rule(_execution), do: nil
end
