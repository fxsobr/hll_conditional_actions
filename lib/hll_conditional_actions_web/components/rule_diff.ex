defmodule HllConditionalActionsWeb.RuleDiff do
  @moduledoc """
  A readable before/after of two rule snapshots
  (`HllConditionalActions.Rules.Snapshot`).

  Scalars read as labels ("Player connects" rather than `player_connected`);
  conditions and actions read as the same sentences the builder summary
  uses, so a reviewer compares what the rule *says* rather than raw JSON.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.RuleBuilder, only: [condition_sentence: 2, exemptions_text: 1]

  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Rules.Condition
  alias HllConditionalActions.Rules.Exemptions

  @scalars ~w(
    name description simulation priority group game server_id trigger_event
    trigger_interval_seconds logical_operator cooldown_seconds
    max_executions_per_player escalation_window_seconds
  )

  @doc """
  The fields that differ between two snapshots, as
  `%{field: "name", label: …, from: [line], to: [line]}`, in a stable order.
  """
  @spec rows(map() | nil, map(), list()) :: [map()]
  def rows(before, now, servers \\ []) do
    before = before || %{}
    game = atom(now["game"]) || :hll

    scalar_rows =
      for field <- @scalars, before[field] != now[field] do
        %{
          field: field,
          label: Labels.rule_field(field),
          from: [scalar(field, before[field], servers)],
          to: [scalar(field, now[field], servers)]
        }
      end

    list_rows =
      for {field, render} <- [
            {"conditions", &conditions(&1, game)},
            {"actions", &actions/1},
            {"exemptions", &exemptions/1}
          ],
          from = render.(before[field]),
          to = render.(now[field]),
          from != to do
        %{field: field, label: label(field), from: from, to: to}
      end

    scalar_rows ++ list_rows
  end

  @doc """
  Renders diff rows, removed lines struck through and added lines beside them.
  """
  attr :rows, :list, required: true
  attr :id, :string, required: true

  def rule_diff(assigns) do
    ~H"""
    <p :if={@rows == []} id={@id} class="text-body-small text-muted">
      {gettext("No differences in the definition.")}
    </p>

    <dl :if={@rows != []} id={@id} class="divide-y divide-base-300 text-body-small">
      <div :for={row <- @rows} class="grid gap-1 py-2 sm:grid-cols-[12rem_1fr]">
        <dt class="font-medium">{row.label}</dt>
        <dd class="grid min-w-0 gap-2 sm:grid-cols-2">
          <ul class="min-w-0 space-y-0.5" aria-label={gettext("Before")}>
            <li :for={line <- row.from} class="break-words text-error line-through">{line}</li>
          </ul>
          <ul class="min-w-0 space-y-0.5" aria-label={gettext("After")}>
            <li :for={line <- row.to} class="break-words text-success">{line}</li>
          </ul>
        </dd>
      </div>
    </dl>
    """
  end

  defp label("exemptions"), do: gettext("Doesn't apply to")
  defp label(field), do: Labels.rule_field(field)

  defp scalar(_field, value, _servers) when value in [nil, ""], do: gettext("(empty)")
  defp scalar("simulation", true, _servers), do: gettext("yes")
  defp scalar("simulation", false, _servers), do: gettext("no")
  defp scalar("game", value, _servers), do: with_atom(value, &Labels.game/1)
  defp scalar("trigger_event", value, _servers), do: with_atom(value, &Labels.trigger/1)

  defp scalar("logical_operator", value, _servers),
    do: with_atom(value, &Labels.logical_operator/1)

  defp scalar("server_id", id, servers) do
    case Enum.find(servers, &(&1.id == id)) do
      nil -> "##{id}"
      server -> server.name
    end
  end

  defp scalar(_field, value, _servers), do: to_string(value)

  defp conditions(rows, game) do
    Enum.map(list(rows), fn row ->
      %Condition{}
      |> Condition.changeset(row)
      |> Ecto.Changeset.apply_changes()
      |> condition_sentence(game)
    end)
  end

  defp actions(rows) do
    Enum.map(list(rows), fn row ->
      action = %Action{} |> Action.changeset(row) |> Ecto.Changeset.apply_changes()
      details = parameters(action.parameters)

      if details == "",
        do: Labels.action(action.type),
        else: "#{Labels.action(action.type)}: #{details}"
    end)
  end

  defp exemptions(row) when is_map(row) and map_size(row) > 0 do
    text =
      %Exemptions{}
      |> Exemptions.changeset(row)
      |> Ecto.Changeset.apply_changes()
      |> exemptions_text()

    [text || gettext("nobody")]
  end

  defp exemptions(_row), do: [gettext("nobody")]

  defp parameters(parameters) when is_map(parameters) do
    parameters
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{short(value)}" end)
  end

  defp parameters(_parameters), do: ""

  defp short(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp short(value), do: value |> Jason.encode!() |> String.slice(0, 80)

  defp list(rows) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp list(_rows), do: []

  defp with_atom(value, fun) do
    case atom(value) do
      nil -> to_string(value)
      atom -> fun.(atom)
    end
  end

  defp atom(value) when is_atom(value), do: value

  defp atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp atom(_value), do: nil
end
