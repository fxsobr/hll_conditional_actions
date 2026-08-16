defmodule HllConditionalActions.Rules.Health do
  @moduledoc """
  Tells an admin when a rule is not doing what they think it is doing.

  A rule that cannot work fails quietly: the action errors, the execution row
  records it, and nobody looks. These checks turn that silence into something
  the rules list can show, and they are the difference between trusting the
  tool and hoping.

  Four things go wrong in practice:

    * **the key cannot do it** — the server's CRCON key lacks the permission
      an action needs, so that action will never land. This is the only check
      that predicts a failure instead of observing one.
    * **it always fails** — it fires and every run errors.
    * **it never fired** — enabled for a while, never once matched. Usually a
      condition nobody meant to write.
    * **it went quiet** — it used to fire and has not in a month.

  Everything is computed from data already held: one grouped query over the
  execution history plus the permission set the connection test stored on the
  server. No CRCON call.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon.Permissions
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @quiet_after_days 30
  @grace_days 7
  @failing_sample 5

  @type issue :: %{
          id: atom(),
          tone: String.t(),
          summary: String.t(),
          detail: String.t() | nil
        }

  @doc """
  The issues of every rule in a list, as `%{rule_id => [issue]}`.

  Takes the servers so the permission check can find each rule's key without
  another query; a fleet-wide rule (no `server_id`) is checked against every
  server it would run on.
  """
  @spec for_rules([Rule.t()], [Server.t()]) :: %{term() => [issue()]}
  def for_rules([], _servers), do: %{}

  def for_rules(rules, servers) do
    stats = execution_stats(Enum.map(rules, & &1.id))

    Map.new(rules, fn rule ->
      {rule.id, issues(rule, Map.get(stats, rule.id, empty_stats()), servers)}
    end)
  end

  @doc """
  The issues of a single rule.
  """
  @spec for_rule(Rule.t(), [Server.t()]) :: [issue()]
  def for_rule(%Rule{} = rule, servers) do
    stats = rule.id |> List.wrap() |> execution_stats() |> Map.get(rule.id, empty_stats())

    issues(rule, stats, servers)
  end

  # ── The checks ─────────────────────────────────────────────────────────────

  defp issues(%Rule{enabled: false}, _stats, _servers), do: []

  defp issues(%Rule{} = rule, stats, servers) do
    [
      permission_issue(rule, servers),
      failing_issue(stats),
      never_fired_issue(rule, stats),
      quiet_issue(stats)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # An action whose permission the key does not hold can never succeed. Only
  # servers we have actually checked are judged: an unchecked key is unknown,
  # not broken.
  defp permission_issue(%Rule{} = rule, servers) do
    targets = servers_for(rule, servers) |> Enum.filter(&(&1.known_permissions != []))

    missing =
      for server <- targets,
          action <- Enum.map(rule.actions, & &1.type),
          permission = Permissions.permission_for(action),
          permission != nil,
          permission not in server.known_permissions,
          uniq: true,
          do: {server.name, action}

    case missing do
      [] ->
        nil

      pairs ->
        actions = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        %{
          id: :missing_permission,
          tone: "error",
          summary: :missing_permission,
          detail: Enum.map_join(actions, ", ", &to_string/1)
        }
    end
  end

  defp failing_issue(%{recent: recent, recent_failed: failed})
       when recent >= @failing_sample and recent == failed do
    %{id: :always_failing, tone: "error", summary: :always_failing, detail: nil}
  end

  defp failing_issue(_stats), do: nil

  defp never_fired_issue(%Rule{inserted_at: inserted_at}, %{total: 0}) do
    if older_than?(inserted_at, @grace_days) do
      %{id: :never_fired, tone: "warning", summary: :never_fired, detail: nil}
    end
  end

  defp never_fired_issue(_rule, _stats), do: nil

  defp quiet_issue(%{total: total, last_executed_at: last}) when total > 0 do
    if older_than?(last, @quiet_after_days) do
      %{id: :quiet, tone: "warning", summary: :quiet, detail: nil}
    end
  end

  defp quiet_issue(_stats), do: nil

  # ── Data ───────────────────────────────────────────────────────────────────

  # One pass for every rule on the page rather than a query per row.
  defp execution_stats(rule_ids) do
    since = DateTime.add(DateTime.utc_now(), -@grace_days * 24 * 60 * 60, :second)

    from(e in Execution,
      where: e.rule_id in ^rule_ids,
      group_by: e.rule_id,
      select: {
        e.rule_id,
        %{
          total: count(e.id),
          last_executed_at: max(e.executed_at),
          recent: filter(count(e.id), e.executed_at >= ^since),
          recent_failed: filter(count(e.id), e.executed_at >= ^since and e.status == ^:failed)
        }
      }
    )
    |> Repo.all()
    |> Map.new()
  end

  defp empty_stats,
    do: %{total: 0, last_executed_at: nil, recent: 0, recent_failed: 0}

  # A rule pinned to a server is judged against it; a fleet-wide rule against
  # every enabled server of its game, which is where it will actually run.
  defp servers_for(%Rule{server_id: nil} = rule, servers) do
    Enum.filter(servers, &(&1.game == rule.game and &1.enabled))
  end

  defp servers_for(%Rule{server_id: id}, servers) do
    Enum.filter(servers, &(&1.id == id))
  end

  defp older_than?(nil, _days), do: false

  defp older_than?(%DateTime{} = at, days) do
    DateTime.diff(DateTime.utc_now(), at, :second) > days * 24 * 60 * 60
  end

  defp older_than?(%NaiveDateTime{} = at, days) do
    at |> DateTime.from_naive!("Etc/UTC") |> older_than?(days)
  end
end
