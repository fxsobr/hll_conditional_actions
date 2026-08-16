defmodule HllConditionalActions.Rules.Audit do
  @moduledoc """
  Writes and reads a rule's change history.

  Every mutation in `HllConditionalActions.Rules` passes through here with the
  user who asked for it. Recording is deliberately best effort: a rule that
  saved must not fail because its audit row could not be written, so a failure
  is logged and swallowed rather than rolled back into the caller's face.

  The diff is computed from the changeset, so an "update" that changed nothing
  writes nothing — the history stays a list of real changes rather than of
  save button presses.
  """

  import Ecto.Query

  require Logger

  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Version

  # Fields worth remembering the before and after of. Conditions and actions
  # are embeds; they are summarised rather than dumped, because a raw embed
  # diff is unreadable and would bloat every row.
  @tracked [
    :name,
    :description,
    :enabled,
    :simulation,
    :priority,
    :group,
    :game,
    :server_id,
    :trigger_event,
    :trigger_interval_seconds,
    :logical_operator,
    :cooldown_seconds,
    :max_executions_per_player,
    :escalation_window_seconds
  ]

  @doc """
  Records that a rule was created, updated, deleted and so on.

  `changeset` is optional: with one, only the fields that really moved are
  stored; without one (a delete, say) the entry is just the fact and the
  actor.
  """
  @spec record(Rule.t(), atom(), map() | nil, Ecto.Changeset.t() | nil) :: :ok
  def record(%Rule{} = rule, action, actor, changeset \\ nil) do
    changes = diff(changeset)

    if action == :updated and changes == %{} do
      :ok
    else
      %Version{}
      |> Version.changeset(%{
        # A delete is recorded *after* the row is gone, so the entry keeps
        # only the name — which is why the schema stores it.
        rule_id: if(action == :deleted, do: nil, else: rule.id),
        rule_name: rule.name,
        user_id: actor && Map.get(actor, :id),
        user_name: actor && (Map.get(actor, :name) || Map.get(actor, :username)),
        action: action,
        changes: changes
      })
      |> Repo.insert()
      |> case do
        {:ok, _version} ->
          :ok

        {:error, changeset} ->
          # The rule saved; losing its audit row must not undo that.
          Logger.error(
            "[audit] could not record #{action} for rule #{rule.id}: #{inspect(changeset.errors)}"
          )

          :ok
      end
    end
  end

  @doc """
  A rule's history, newest first.
  """
  @spec list_versions(term(), keyword()) :: [Version.t()]
  def list_versions(rule_id, opts \\ []) do
    Version
    |> where([v], v.rule_id == ^rule_id)
    |> order_by([v], desc: v.inserted_at, desc: v.id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc """
  How many entries a rule's history holds.
  """
  @spec count_versions(term()) :: non_neg_integer()
  def count_versions(rule_id) do
    Repo.one(from v in Version, where: v.rule_id == ^rule_id, select: count(v.id)) || 0
  end

  # ── The diff ───────────────────────────────────────────────────────────────

  defp diff(nil), do: %{}

  defp diff(%Ecto.Changeset{} = changeset) do
    scalar = Enum.reduce(@tracked, %{}, &scalar_change(&1, changeset, &2))

    Enum.reduce([:conditions, :actions], scalar, &embed_change(&1, changeset, &2))
  end

  defp scalar_change(field, changeset, acc) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, new} ->
        Map.put(acc, to_string(field), %{
          "from" => printable(Map.get(changeset.data, field)),
          "to" => printable(new)
        })

      :error ->
        acc
    end
  end

  # An embed diff is only useful as "there were 2, now there are 3": the rows
  # themselves are shown by the rule itself, not by its history.
  defp embed_change(field, changeset, acc) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, rows} ->
        before = length(Map.get(changeset.data, field) || [])
        now = Enum.count(rows, &kept?/1)

        entry = %{"from" => "#{before}", "to" => "#{now}"}

        # Same count, different content: the numbers alone would read as "no
        # change", so the entry carries a flag the history renders as "edited".
        entry = if before == now, do: Map.put(entry, "edited", true), else: entry

        Map.put(acc, to_string(field), entry)

      :error ->
        acc
    end
  end

  # An `embeds_many` replacement keeps the outgoing rows in the change list,
  # marked `:replace`, alongside the incoming ones. Counting the list whole
  # would report four actions becoming eight.
  defp kept?(%Ecto.Changeset{action: action}) when action in [:replace, :delete], do: false
  defp kept?(_row), do: true

  defp printable(nil), do: nil
  defp printable(value) when is_binary(value), do: String.slice(value, 0, 120)
  defp printable(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp printable(value) when is_atom(value), do: to_string(value)
  defp printable(value), do: inspect(value)
end
