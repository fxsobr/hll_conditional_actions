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
  Renders diff rows as before and after, side by side: what was removed on
  the left in the error tint, what replaced it on the right in the signal,
  the field named above each pair.
  """
  attr :rows, :list, required: true
  attr :id, :string, required: true
  attr :before_label, :string, default: nil
  attr :after_label, :string, default: nil

  def rule_diff(assigns) do
    assigns =
      assigns
      |> assign_new(:before_text, fn -> assigns.before_label || gettext("Before") end)
      |> assign_new(:after_text, fn -> assigns.after_label || gettext("After") end)

    ~H"""
    <p :if={@rows == []} id={@id} class="text-[0.8125rem] text-muted">
      {gettext("No differences in the definition.")}
    </p>

    <div :if={@rows != []} id={@id} class="flex flex-col gap-3">
      <div class="hidden grid-cols-2 gap-2.5 text-[0.6875rem] uppercase tracking-[0.08em] sm:grid">
        <span class="text-error">{@before_text}</span>
        <span class="text-primary">{@after_text}</span>
      </div>

      <div :for={row <- @rows} class="flex flex-col gap-1.5">
        <p class="text-xs font-medium text-subtle">{row.label}</p>
        <div class="grid min-w-0 gap-2 sm:grid-cols-2">
          <ul
            class="flex min-w-0 flex-col gap-1 rounded-xl bg-error/10 px-3 py-2 font-mono text-xs leading-relaxed text-error"
            aria-label={@before_text}
          >
            <li :for={line <- row.from} class="flex gap-2 break-words">
              <span aria-hidden="true" class="select-none opacity-70">−</span>
              <del class="decoration-error/50">{line}</del>
            </li>
          </ul>
          <ul
            class="flex min-w-0 flex-col gap-1 rounded-xl bg-primary/10 px-3 py-2 font-mono text-xs leading-relaxed text-primary ring-1 ring-primary/25"
            aria-label={@after_text}
          >
            <li :for={line <- row.to} class="flex gap-2 break-words">
              <span aria-hidden="true" class="select-none opacity-70">+</span>
              <ins class="no-underline">{line}</ins>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp label("exemptions"), do: gettext("Doesn't apply to")
  defp label(field), do: Labels.rule_field(field)

  # ── Whole definitions, line by line ────────────────────────────────────────

  @doc """
  A snapshot as the numbered lines of the versions tab, in reading order:
  `[{key, label, value}]`. Keys are stable across versions, so two lists line
  up by key.
  """
  @spec field_lines(map() | nil, list()) :: [{String.t(), String.t(), String.t()}]
  def field_lines(nil, _servers), do: []

  def field_lines(snapshot, servers) do
    game = atom(snapshot["game"]) || :hll

    conditions =
      conditions(Enum.reject(list(snapshot["conditions"]), &(&1["field"] == "always_true")), game)

    actions = Enum.map(list(snapshot["actions"]), &action_line/1)
    window = snapshot["escalation_window_seconds"] || 0
    ladder? = window > 0 and length(actions) > 1

    head = [
      {"trigger", gettext("trigger"),
       lower_first(scalar("trigger_event", snapshot["trigger_event"], servers))},
      {"scope", gettext("scope"), scope(snapshot, servers)}
    ]

    condition_lines =
      for {text, index} <- Enum.with_index(conditions, 1) do
        {"condition-#{index}", gettext("condition %{number}", number: index), text}
      end

    head ++
      condition_lines ++
      logic_line(conditions, snapshot, servers) ++
      window_line(ladder?, window) ++
      action_lines(actions, ladder?) ++ tail_lines(snapshot, servers)
  end

  defp logic_line([_, _ | _], snapshot, servers) do
    [
      {"logic", gettext("combination"),
       lower_first(scalar("logical_operator", snapshot["logical_operator"], servers))}
    ]
  end

  defp logic_line(_conditions, _snapshot, _servers), do: []

  defp window_line(true, window),
    do: [{"window", gettext("ladder window"), short_duration(window)}]

  defp window_line(false, _window), do: []

  defp action_lines(actions, ladder?) do
    for {text, index} <- Enum.with_index(actions, 1) do
      label =
        if ladder?,
          do: gettext("step %{number}", number: index),
          else: gettext("action %{number}", number: index)

      {"action-#{index}", label, lower_first(text)}
    end
  end

  defp tail_lines(snapshot, servers) do
    [
      {"cooldown", gettext("cooldown"), cooldown(snapshot["cooldown_seconds"])},
      {"cap", gettext("limit"), cap(snapshot["max_executions_per_player"])},
      {"exemptions", gettext("exemptions"), hd(exemptions(snapshot["exemptions"]))},
      {"priority", gettext("priority"), to_string(snapshot["priority"] || 0)},
      {"simulation", gettext("simulation"),
       scalar("simulation", snapshot["simulation"] == true, servers)},
      {"group", gettext("folder"), present_text(snapshot["group"])},
      {"name", gettext("name"), present_text(snapshot["name"])}
    ]
  end

  @doc """
  Two line lists side by side, aligned by key: `[{before | nil, after | nil,
  changed?}]` where each side is `{number, label, value}`.
  """
  @spec align([tuple()], [tuple()]) :: [{tuple() | nil, tuple() | nil, boolean()}]
  def align(before, now) do
    before_map = Map.new(before, fn {key, label, value} -> {key, {label, value}} end)
    now_map = Map.new(now, fn {key, label, value} -> {key, {label, value}} end)

    keys =
      (Enum.map(now, &elem(&1, 0)) ++ Enum.map(before, &elem(&1, 0)))
      |> Enum.uniq()
      |> Enum.sort_by(fn key ->
        Enum.find_index(now, &(elem(&1, 0) == key)) ||
          (Enum.find_index(before, &(elem(&1, 0) == key)) || 0) + 0.5
      end)

    {rows, _numbers} =
      Enum.map_reduce(keys, {1, 1}, fn key, {left, right} ->
        a = Map.get(before_map, key)
        b = Map.get(now_map, key)
        left_row = a && {left, elem(a, 0), elem(a, 1)}
        right_row = b && {right, elem(b, 0), elem(b, 1)}
        changed = (a && elem(a, 1)) != (b && elem(b, 1))

        {{left_row, right_row, changed},
         {if(a, do: left + 1, else: left), if(b, do: right + 1, else: right)}}
      end)

    rows
  end

  @doc """
  A version in a few words, for the list of versions: what the change was
  about ("Started simulating", "Ladder window, cooldown").
  """
  @spec title(map(), map() | nil) :: String.t()
  def title(%{action: :created}, _previous), do: gettext("Created")
  def title(%{action: :imported}, _previous), do: gettext("Imported")
  def title(%{action: :duplicated}, _previous), do: gettext("Created as a copy")
  def title(%{action: :enabled}, _previous), do: gettext("Turned on")
  def title(%{action: :disabled}, _previous), do: gettext("Turned off")
  def title(%{action: :paused}, _previous), do: gettext("Paused")
  def title(%{action: :resumed}, _previous), do: gettext("Resumed")

  def title(%{snapshot: now} = version, previous) when is_map(now) and is_map(previous) do
    cond do
      previous["simulation"] == false and now["simulation"] == true ->
        gettext("Started simulating")

      previous["simulation"] == true and now["simulation"] == false ->
        gettext("Started acting for real")

      true ->
        changed_labels(version, previous)
    end
  end

  def title(version, previous), do: changed_labels(version, previous)

  defp changed_labels(version, previous) do
    labels =
      case {version.snapshot, previous} do
        {now, before} when is_map(now) and is_map(before) ->
          now |> rows_labels(before)

        _other ->
          version.changes |> Map.keys() |> Enum.map(&label/1)
      end

    case labels do
      [] ->
        gettext("No change to the definition")

      [one] ->
        one

      [a, b] ->
        gettext("%{a} and %{b}", a: a, b: lower_first(b))

      [a, b | rest] ->
        gettext("%{a}, %{b} and %{count} more", a: a, b: lower_first(b), count: length(rest))
    end
  end

  # The lines of the versions tab that moved, by their short labels; the
  # history's field names when only something outside them (the
  # description) changed.
  defp rows_labels(now, before) do
    case changed_lines(before, now) do
      [] -> now |> then(&rows(before, &1)) |> Enum.map(& &1.label)
      labels -> Enum.map(labels, &upper_first/1)
    end
  end

  defp changed_lines(before, now) do
    before
    |> field_lines([])
    |> align(field_lines(now, []))
    |> Enum.filter(&elem(&1, 2))
    |> Enum.map(fn {left, right, _changed} -> elem(right || left, 1) end)
    |> Enum.uniq()
  end

  @doc """
  The lines that changed between two snapshots, as `{label, before, after}`
  (a side is `nil` when the line is new or gone), for the change card.
  """
  @spec changes(map(), map(), list()) :: [{String.t(), String.t() | nil, String.t() | nil}]
  def changes(before, now, servers) do
    before
    |> field_lines(servers)
    |> align(field_lines(now, servers))
    |> Enum.filter(&elem(&1, 2))
    |> Enum.map(fn {left, right, _changed} ->
      {elem(right || left, 1), left && elem(left, 2), right && elem(right, 2)}
    end)
  end

  defp upper_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upper_first(text), do: text

  @doc """
  Who changed what, as one sentence: "Marcelo changed the ladder window and
  the cooldown."
  """
  @spec note(String.t() | nil, [map() | tuple()]) :: String.t()
  def note(user, rows) do
    user = user || gettext("the system")

    labels =
      Enum.map(rows, fn
        {label, _before, _after} -> label
        row -> lower_first(row.label)
      end)

    case labels do
      [] -> gettext("%{user} changed nothing in the definition.", user: user)
      [one] -> gettext("%{user} changed %{what}.", user: user, what: one)
      many -> gettext("%{user} changed %{what}.", user: user, what: join_words(many))
    end
  end

  defp join_words([a, b]), do: gettext("%{a} and %{b}", a: a, b: b)

  defp join_words(words) do
    {init, [last]} = Enum.split(words, -1)
    gettext("%{a} and %{b}", a: Enum.join(init, ", "), b: last)
  end

  defp scope(snapshot, servers) do
    case snapshot["server_id"] do
      nil ->
        gettext("every %{game} server",
          game: if(atom(snapshot["game"]) == :hllv, do: "HLL Vietnam", else: "HLL")
        )

      id ->
        scalar("server_id", id, servers)
    end
  end

  defp cooldown(seconds) when seconds in [nil, 0], do: gettext("none")
  defp cooldown(seconds), do: short_duration(seconds)

  defp cap(max) when max in [nil, 0], do: gettext("none")
  defp cap(max), do: gettext("%{count} per player in 24 h", count: max)

  defp short_duration(seconds) when rem(seconds, 3600) == 0, do: "#{div(seconds, 3600)} h"
  defp short_duration(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  defp short_duration(seconds), do: "#{seconds} s"

  defp present_text(value) when value in [nil, ""], do: "—"
  defp present_text(value), do: to_string(value)

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(text), do: text

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

  # An action as one line of the versions tab: what it does, then the text
  # the player would read, since that is what an edit usually touches.
  defp action_line(row) do
    action = %Action{} |> Action.changeset(row) |> Ecto.Changeset.apply_changes()
    params = action.parameters || %{}
    text = params["message"] || params["reason"] || params["content"]
    head = HllConditionalActionsWeb.RuleComponents.action_text(action)

    if is_binary(text) and text != "", do: "#{head} · “#{text}”", else: head
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
