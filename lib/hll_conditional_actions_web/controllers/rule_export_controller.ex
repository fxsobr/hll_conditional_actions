defmodule HllConditionalActionsWeb.RuleExportController do
  @moduledoc """
  Downloads rules as JSON, and executions as CSV (`?format=csv`).

  A controller rather than a LiveView event, because handing the browser a file
  needs a real HTTP response with `content-disposition`.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Transfer

  # A download is a report, not a backup: past this many rows the history's
  # filters are the better tool.
  @csv_limit 20_000

  def export(conn, %{"format" => "csv"} = params) do
    user = conn.assigns.current_user

    if Accounts.can?(user, :view_executions) do
      # Scoped like the history itself.
      executions =
        Rules.list_executions_for(user, execution_filters(params) ++ [limit: @csv_limit])

      filename =
        "hll-conditional-actions-executions-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, executions_csv(executions))
    else
      deny(conn)
    end
  end

  def export(conn, params) do
    user = conn.assigns.current_user

    if Accounts.can?(user, :view_rules) do
      # Scoped like the list itself: an export must never be a way around the
      # per-server restriction.
      rules = Rules.list_rules_for(user, filters(params))
      filename = Transfer.filename(DateTime.utc_now())

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, Rules.export_rules(rules))
    else
      deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_flash(:error, gettext("You do not have access to that page."))
    |> redirect(to: ~p"/")
  end

  # The same filters the list applies, so the download holds what the admin
  # was looking at; `ids` is the list's selection.
  defp filters(params) do
    [
      game: cast_game(params["game"]),
      server_id: cast_id(params["server_id"]),
      group: blank_to_nil(params["group"]),
      search: blank_to_nil(params["search"]),
      ids: cast_ids(params["ids"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp execution_filters(params) do
    [
      rule_id: cast_id(params["rule_id"]),
      server_id: cast_id(params["server_id"]),
      status: cast_status(params["status"]),
      player: blank_to_nil(params["player"]),
      from: cast_time(params["from"]),
      until: cast_time(params["until"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @columns ~w(executed_at rule server player_id player_name trigger status step actions duration_ms error)

  # One row per execution; values that may hold a comma, a quote or a line
  # break are quoted the RFC 4180 way.
  defp executions_csv(executions) do
    rows =
      Enum.map(executions, fn execution ->
        trace = execution.trace || %{}

        [
          DateTime.to_iso8601(execution.executed_at),
          execution.rule && execution.rule.name,
          execution.server && execution.server.name,
          execution.player_id,
          execution.player_name,
          execution.trigger_event,
          execution.status,
          trace["step"] && "#{trace["step"]}/#{trace["steps"]}",
          Enum.map_join(execution.results || [], " ", &"#{&1["type"]}:#{&1["status"]}"),
          trace["duration_ms"],
          execution.error
        ]
      end)

    [@columns | rows]
    |> Enum.map_join("\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: ~s(") <> String.replace(text, ~s("), ~s("")) <> ~s("),
      else: text
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp cast_ids(ids) when is_binary(ids) and ids != "" do
    ids |> String.split(",") |> Enum.map(&cast_id/1) |> Enum.reject(&is_nil/1)
  end

  defp cast_ids(_ids), do: nil

  defp cast_game(game) when game in ["hll", "hllv"], do: String.to_existing_atom(game)
  defp cast_game(_game), do: nil

  defp cast_status(status) when status in ~w(executed partial failed simulated),
    do: String.to_existing_atom(status)

  defp cast_status(_status), do: nil

  defp cast_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp cast_time(_value), do: nil

  defp cast_id(nil), do: nil

  defp cast_id(id) do
    case Integer.parse(to_string(id)) do
      {int, ""} -> int
      _other -> nil
    end
  end
end
