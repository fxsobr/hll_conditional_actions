defmodule HllConditionalActions.Attention do
  @moduledoc """
  The attention inbox: what needs an admin now, in one list.

  Items are computed from what already exists - stream status, rule health,
  the execution history - rather than stored, so they appear and disappear on
  their own when the underlying thing changes. What *is* stored is which
  items somebody marked as handled (`attention_reviews`), keyed so that a
  new occurrence comes back: failures are keyed by their latest execution,
  so a rule that fails again after being handled shows up again.

  Kinds, most urgent first:

    * `:stream_down` - an enabled server's live log stream is in error
    * `:ticket_waiting` - a player's ticket waited longer than the server
      allows (`attention_minutes` in the ticket settings)
    * `:rule_broken` - a rule that can never work, or fails every time
    * `:failures` - a rule whose actions failed in the last day
    * `:review` - a player a rule put on the watchlist or flagged, for a
      human to look at (the HQ vehicle guard lands here)
    * `:ready_to_go_live` - a rule simulating for days without a failure
    * `:rule_quiet` - a rule that never fires, or stopped firing
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention.Review
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Health
  alias HllConditionalActions.Tickets

  @type item :: %{
          key: String.t(),
          kind: atom(),
          severity: :error | :warning | :info,
          at: DateTime.t() | nil,
          subject: map(),
          resolvable?: boolean()
        }

  @review_actions ~w(add_to_watchlist add_player_flag)
  @review_window_days 7
  @failure_window_hours 24
  # A simulating rule is ready to act by the rule page's own measure: three
  # days simulating, some runs and no failure (`RuleLive.Show`).
  @simulation_days 3

  @severity_order %{error: 0, warning: 1, info: 2}

  @doc """
  The open items for a user, most urgent first, and how many were handled.
  """
  @spec items(map(), [map()], %{optional(term()) => term()}) ::
          %{open: [item()], handled: non_neg_integer()}
  def items(user, servers, stream_status) do
    server_ids = Enum.map(servers, & &1.id)

    rules =
      if Accounts.can?(user, :view_rules) do
        user
        |> Rules.list_rules_for()
        |> Enum.filter(&applies?(&1, servers))
      else
        []
      end

    all =
      stream_items(servers, stream_status) ++
        ticket_items(user, server_ids) ++
        rule_items(rules, servers) ++
        failure_items(user, server_ids) ++
        review_items(user, server_ids) ++
        go_live_items(user, rules) ++
        shop_items(user)

    handled = handled_keys(Enum.map(all, & &1.key))
    {done, open} = Enum.split_with(all, &MapSet.member?(handled, &1.key))

    %{
      open: Enum.sort_by(open, &{@severity_order[&1.severity], sort_time(&1.at)}),
      handled: length(done)
    }
  end

  @topic "attention"

  @doc """
  Subscribes to `{:attention_changed, nil}`, sent whenever something that
  can add or remove an item happens: a rule ran, a stream went up or down,
  a rule changed, an item was handled. The count is then worth reading
  again - the message says nothing about what changed.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, @topic)

  @doc "Tells the subscribers the items may have changed."
  @spec notify_changed() :: :ok
  def notify_changed do
    Phoenix.PubSub.broadcast(HllConditionalActions.PubSub, @topic, {:attention_changed, nil})
  end

  @doc "How many items are open, for a badge."
  @spec count(map(), [map()], map()) :: non_neg_integer()
  def count(user, servers, stream_status),
    do: length(items(user, servers, stream_status).open)

  @doc """
  Marks an item as handled by a user. Handling it twice is harmless.
  """
  @spec resolve(String.t(), map()) :: :ok
  def resolve(key, user) when is_binary(key) do
    %Review{}
    |> Review.changeset(%{key: key, user_id: user && user.id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :key)

    notify_changed()
  end

  # ── Sources ────────────────────────────────────────────────────────────────

  defp stream_items(servers, stream_status) do
    for server <- servers,
        server.enabled,
        reason = stream_problem(stream_status[server.id]),
        reason != nil do
      %{
        key: "stream:#{server.id}",
        kind: :stream_down,
        severity: :error,
        at: nil,
        subject: %{server: server, reason: reason},
        resolvable?: false
      }
    end
  end

  defp ticket_items(user, server_ids) do
    if Accounts.can?(user, :view_tickets) do
      for ticket <- Tickets.overdue(server_ids) do
        %{
          key: "ticket:#{ticket.id}",
          kind: :ticket_waiting,
          severity: :error,
          at: ticket.last_activity_at,
          subject: %{ticket: ticket},
          resolvable?: false
        }
      end
    else
      []
    end
  end

  defp rule_items(rules, servers) do
    health = Health.for_rules(rules, servers)

    # A switched-off rule is only told on its own page and in the list.
    for rule <- rules, rule.enabled, issue <- Map.get(health, rule.id, []) do
      {kind, severity} =
        case issue.id do
          id when id in [:missing_permission, :always_failing] -> {:rule_broken, :error}
          :contradiction -> {:rule_broken, :warning}
          _quiet -> {:rule_quiet, :info}
        end

      %{
        key: "health:#{issue.id}:#{rule.id}",
        kind: kind,
        severity: severity,
        at: nil,
        subject: %{rule: rule, issue: issue},
        resolvable?: kind == :rule_quiet
      }
    end
  end

  # A rule belongs to the inbox of the servers it runs on.
  defp applies?(%{server_id: nil, game: game}, servers),
    do: Enum.any?(servers, &(&1.game == game))

  defp applies?(%{server_id: id}, servers), do: Enum.any?(servers, &(&1.id == id))

  defp failure_items(user, server_ids) do
    since = DateTime.add(DateTime.utc_now(), -@failure_window_hours, :hour)

    user
    |> Rules.scoped_executions()
    |> where([e], e.server_id in ^server_ids)
    |> where([e], e.executed_at >= ^since and e.status in [:failed, :partial])
    |> Repo.all()
    |> Repo.preload(:rule)
    |> Enum.group_by(& &1.rule_id)
    |> Enum.map(fn {rule_id, executions} ->
      latest = Enum.max_by(executions, & &1.id)

      %{
        key: "failures:#{rule_id}:#{latest.id}",
        kind: :failures,
        severity: :warning,
        at: latest.executed_at,
        subject: %{rule: latest.rule, count: length(executions), error: latest.error},
        resolvable?: true
      }
    end)
  end

  # A paid VIP that did not reach every server: money was taken, so it is
  # the most urgent thing a shop admin can be told.
  defp shop_items(user) do
    if Accounts.can?(user, :manage_integrations) do
      Enum.map(HllConditionalActions.VipShop.failed_orders(), fn order ->
        %{
          key: "vip_order:#{order.id}:#{order.status}",
          kind: :vip_failed,
          severity: :error,
          at: order.updated_at,
          subject: %{order: order},
          resolvable?: true
        }
      end)
    else
      []
    end
  end

  defp review_items(user, server_ids) do
    since = DateTime.add(DateTime.utc_now(), -@review_window_days, :day)

    user
    |> Rules.scoped_executions()
    |> where([e], e.server_id in ^server_ids)
    |> where([e], e.executed_at >= ^since and not is_nil(e.player_id))
    |> order_by([e], desc: e.executed_at)
    |> limit(500)
    |> Repo.all()
    |> Enum.filter(&Enum.any?(&1.results, fn result -> result["type"] in @review_actions end))
    |> Repo.preload([:rule, :server])
    |> Enum.map(fn execution ->
      result = Enum.find(execution.results, &(&1["type"] in @review_actions))

      %{
        key: "review:#{execution.id}",
        kind: :review,
        severity: :warning,
        at: execution.executed_at,
        subject: %{execution: execution, reason: result["detail"]},
        resolvable?: true
      }
    end)
  end

  defp go_live_items(user, rules) do
    cutoff = DateTime.add(DateTime.utc_now(), -@simulation_days, :day)

    candidates =
      Enum.filter(rules, fn rule ->
        rule.enabled and rule.simulation and DateTime.compare(rule.inserted_at, cutoff) == :lt
      end)

    counts = simulated_counts(user, Enum.map(candidates, & &1.id), cutoff)

    for rule <- candidates,
        {runs, failures, last} = Map.get(counts, rule.id, {0, 0, nil}),
        runs > 0 and failures == 0 do
      %{
        key: "go_live:#{rule.id}",
        kind: :ready_to_go_live,
        severity: :info,
        at: last,
        subject: %{rule: rule, runs: runs},
        resolvable?: true
      }
    end
  end

  defp simulated_counts(_user, [], _cutoff), do: %{}

  defp simulated_counts(user, rule_ids, cutoff) do
    user
    |> Rules.scoped_executions()
    |> where([e], e.rule_id in ^rule_ids)
    |> group_by([e], e.rule_id)
    |> select([e], {
      e.rule_id,
      {filter(count(e.id), e.status == :simulated),
       filter(count(e.id), e.status in [:failed, :partial] and e.executed_at >= ^cutoff),
       filter(max(e.executed_at), e.status == :simulated)}
    })
    |> Repo.all()
    |> Map.new()
  end

  # An error the stream reported, or `:stopped` when the server's engine is
  # not running at all.
  defp stream_problem({:error, reason}), do: format_reason(reason)
  # With the engine off (by configuration) no stream is expected to run.
  defp stream_problem(:disconnected),
    do: if(HllConditionalActions.Runtime.enabled?(), do: :stopped)

  defp stream_problem(_fine), do: nil

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp handled_keys([]), do: MapSet.new()

  defp handled_keys(keys) do
    Review
    |> where([r], r.key in ^keys)
    |> select([r], r.key)
    |> Repo.all()
    |> MapSet.new()
  end

  # Newest first within a severity; items without a time go last.
  defp sort_time(nil), do: 0
  defp sort_time(%DateTime{} = at), do: -DateTime.to_unix(at)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)
end
