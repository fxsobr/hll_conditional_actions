defmodule HllConditionalActionsWeb.RuleExportController do
  @moduledoc """
  Downloads rules as JSON.

  A controller rather than a LiveView event, because handing the browser a file
  needs a real HTTP response with `content-disposition`.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Transfer

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
      conn
      |> put_flash(:error, gettext("You do not have access to that page."))
      |> redirect(to: ~p"/")
    end
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

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp cast_ids(ids) when is_binary(ids) and ids != "" do
    ids |> String.split(",") |> Enum.map(&cast_id/1) |> Enum.reject(&is_nil/1)
  end

  defp cast_ids(_ids), do: nil

  defp cast_game(game) when game in ["hll", "hllv"], do: String.to_existing_atom(game)
  defp cast_game(_game), do: nil

  defp cast_id(nil), do: nil

  defp cast_id(id) do
    case Integer.parse(to_string(id)) do
      {int, ""} -> int
      _other -> nil
    end
  end
end
