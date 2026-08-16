defmodule HllConditionalActions.Rules.Transfer do
  @moduledoc """
  Moves rules between installs as JSON.

  Useful for keeping a rule set in git, copying a tested rule from a staging
  server to production, or sharing one with another community.

  ## What travels

  Only what describes the rule: its trigger, conditions, actions and limits.
  Deliberately left out:

    * `server_id` - an id from another database means nothing here, so an
      imported rule arrives fleet-wide and the importer picks a target
    * `id`, timestamps - the importer creates new records
    * anything from the execution history

  `game` does travel, because a rule written against Vietnam's roles is not
  valid for WW2 and silently importing it would produce a rule that never
  fires.

  ## Format

      {
        "format": "hll_conditional_actions.rules",
        "version": 1,
        "exported_at": "2026-08-16T00:00:00Z",
        "rules": [ … ]
      }

  `version` is checked on import so a future format change can be rejected
  with a clear message instead of a confusing validation error.
  """

  alias HllConditionalActions.Rules.Rule

  @format "hll_conditional_actions.rules"
  @version 1

  @exported_fields ~w(
    name description enabled simulation priority game trigger_event
    trigger_interval_seconds logical_operator cooldown_seconds
    max_executions_per_player
  )a

  @doc """
  Builds the export payload for a list of rules.
  """
  @spec export([Rule.t()], DateTime.t()) :: map()
  def export(rules, now \\ DateTime.utc_now()) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.to_iso8601(now),
      "rules" => Enum.map(rules, &dump/1)
    }
  end

  @doc """
  Encodes an export as pretty-printed JSON, so a diff of a checked-in file is
  readable.
  """
  @spec encode([Rule.t()], DateTime.t()) :: String.t()
  def encode(rules, now \\ DateTime.utc_now()) do
    rules |> export(now) |> Jason.encode!(pretty: true)
  end

  @doc """
  A file name for a download.

      iex> HllConditionalActions.Rules.Transfer.filename(~U[2026-08-16 12:30:00Z])
      "hll-conditional-actions-rules-20260816-1230.json"
  """
  @spec filename(DateTime.t()) :: String.t()
  def filename(now \\ DateTime.utc_now()) do
    "hll-conditional-actions-rules-#{Calendar.strftime(now, "%Y%m%d-%H%M")}.json"
  end

  @doc """
  Parses and validates an export payload.

  Returns the rule attribute maps ready for
  `HllConditionalActions.Rules.create_rule/1`, without touching the database,
  so the UI can preview what an import would create.
  """
  @spec decode(String.t() | map()) :: {:ok, [map()]} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, payload} -> decode(payload)
      {:error, _reason} -> {:error, "that is not valid JSON"}
    end
  end

  def decode(%{"rules" => rules} = payload) when is_list(rules) do
    with :ok <- check_format(payload),
         :ok <- check_version(payload) do
      {:ok, Enum.map(rules, &load/1)}
    end
  end

  def decode(_payload), do: {:error, "the file has no \"rules\" list"}

  @doc """
  The format identifier written into every export.
  """
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  The format version this module writes and accepts.
  """
  @spec version() :: pos_integer()
  def version, do: @version

  # ── Internals ──────────────────────────────────────────────────────────────

  defp dump(%Rule{} = rule) do
    rule
    |> Map.take(@exported_fields)
    |> Map.new(fn {key, value} -> {to_string(key), stringify(value)} end)
    |> Map.put("conditions", Enum.map(rule.conditions, &dump_condition/1))
    |> Map.put("actions", Enum.map(rule.actions, &dump_action/1))
  end

  defp dump_condition(condition) do
    %{
      "field" => to_string(condition.field),
      "operator" => to_string(condition.operator),
      "value" => condition.value
    }
  end

  defp dump_action(action) do
    %{"type" => to_string(action.type), "parameters" => action.parameters}
  end

  # Import produces plain attribute maps and lets the changeset reject anything
  # invalid, so a hand-edited file fails with the same messages the form gives.
  defp load(rule) when is_map(rule) do
    rule
    |> Map.take(Enum.map(@exported_fields, &to_string/1))
    |> Map.put("conditions", Enum.map(list(rule["conditions"]), &load_condition/1))
    |> Map.put("actions", Enum.map(list(rule["actions"]), &load_action/1))
    # An imported rule is never pinned to a server: the ids of another install
    # are meaningless here.
    |> Map.put("server_id", nil)
  end

  defp load(_rule), do: %{}

  defp load_condition(condition) when is_map(condition) do
    Map.take(condition, ~w(field operator value))
  end

  defp load_condition(_condition), do: %{}

  defp load_action(action) when is_map(action) do
    %{
      "type" => action["type"],
      "parameters" => if(is_map(action["parameters"]), do: action["parameters"], else: %{})
    }
  end

  defp load_action(_action), do: %{}

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp stringify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp stringify(value), do: value

  defp check_format(%{"format" => @format}), do: :ok
  defp check_format(%{"format" => other}), do: {:error, "unknown export format #{inspect(other)}"}
  # Older hand-written files may have no marker; the rule list is validated
  # anyway, so this is not worth refusing over.
  defp check_format(_payload), do: :ok

  defp check_version(%{"version" => version}) when is_integer(version) and version > @version do
    {:error,
     "this file was written by a newer version (format #{version}, this install reads #{@version})"}
  end

  defp check_version(_payload), do: :ok
end
