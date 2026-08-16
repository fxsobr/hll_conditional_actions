defmodule HllConditionalActions.Rules do
  @moduledoc """
  Manages conditional rules and their execution history.

  Rule changes are broadcast on `"rules"` so every running
  `HllConditionalActions.Engine.Runner` can reload without polling the
  database on each game event.
  """

  import Ecto.Query

  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Transfer
  alias HllConditionalActions.Servers.Server

  @topic "rules"

  @doc """
  Subscribes the calling process to `{:rules_changed, rule}` messages.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  # ── Rules ──────────────────────────────────────────────────────────────────

  @doc """
  Lists rules.

  ## Options

    * `:game` - only rules for a game
    * `:server_id` - only rules pinned to a server
    * `:enabled` - only enabled or disabled rules
    * `:trigger_event` - only rules with a trigger
  """
  @spec list_rules(keyword()) :: [Rule.t()]
  def list_rules(opts \\ []) do
    Rule
    |> filter_rules(opts)
    |> order_by([r], desc: r.priority, asc: r.name)
    |> preload(:server)
    |> Repo.all()
  end

  @doc """
  Lists the enabled rules that apply to a server, sorted the way the engine
  evaluates them.

  This is the query `HllConditionalActions.Engine.Runner` caches: rules pinned
  to the server plus the fleet-wide rules for its game.
  """
  @spec list_active_rules_for(Server.t()) :: [Rule.t()]
  def list_active_rules_for(%Server{id: id, game: game}) do
    Rule
    |> where([r], r.enabled == true and r.game == ^game)
    |> where([r], is_nil(r.server_id) or r.server_id == ^id)
    |> Repo.all()
    |> Rule.sort()
  end

  @doc """
  Lists every rule that applies to a server, enabled or not.

  `list_active_rules_for/1` answers "what is the engine running"; this one
  answers "what is written for this server", which is what the server page
  shows - a rule that is switched off is still part of the setup, and hiding
  it made the page look empty.
  """
  @spec list_rules_applying_to(Server.t()) :: [Rule.t()]
  def list_rules_applying_to(%Server{id: id, game: game}) do
    Rule
    |> where([r], r.game == ^game)
    |> where([r], is_nil(r.server_id) or r.server_id == ^id)
    |> Repo.all()
    |> Rule.sort()
  end

  @doc """
  Lists the rules a user may see.

  A restricted user sees rules pinned to their servers, plus the fleet-wide
  rules for those servers' games - those do affect their servers, so hiding
  them would be misleading. `editable_by?/2` is what decides whether they may
  change one.
  """
  @spec list_rules_for(map() | nil, keyword()) :: [Rule.t()]
  def list_rules_for(user, opts \\ []) do
    case HllConditionalActions.Accounts.server_scope(user) do
      :all ->
        list_rules(opts)

      ids ->
        games = games_of(ids)

        Rule
        |> filter_rules(opts)
        |> where([r], r.server_id in ^ids or (is_nil(r.server_id) and r.game in ^games))
        |> order_by([r], desc: r.priority, asc: r.name)
        |> preload(:server)
        |> Repo.all()
    end
  end

  @doc """
  Whether a user may change a rule.

  A restricted user may only edit rules pinned to one of their own servers:
  a fleet-wide rule reaches servers they do not administer, so changing it is
  not theirs to do.
  """
  @spec editable_by?(Rule.t(), map() | nil) :: boolean()
  def editable_by?(%Rule{} = rule, user) do
    case HllConditionalActions.Accounts.server_scope(user) do
      :all -> true
      ids -> rule.server_id in ids
    end
  end

  defp games_of(server_ids) do
    Repo.all(
      from s in HllConditionalActions.Servers.Server,
        where: s.id in ^server_ids,
        distinct: true,
        select: s.game
    )
  end

  @doc """
  Fetches a rule with its server preloaded, raising if it does not exist.
  """
  @spec get_rule!(term()) :: Rule.t()
  def get_rule!(id), do: Rule |> Repo.get!(id) |> Repo.preload(:server)

  @doc """
  Creates a rule.
  """
  @spec create_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs, opts \\ []) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert()
    |> audit(Keyword.get(opts, :action, :created), Keyword.get(opts, :actor))
    |> broadcast()
  end

  @doc """
  Updates a rule.
  """
  @spec update_rule(Rule.t(), map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def update_rule(%Rule{} = rule, attrs, opts \\ []) do
    changeset = Rule.changeset(rule, attrs)

    changeset
    |> Repo.update()
    |> audit(Keyword.get(opts, :action, :updated), Keyword.get(opts, :actor), changeset)
    |> broadcast()
  end

  @doc """
  Deletes a rule and its execution history.
  """
  @spec delete_rule(Rule.t()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def delete_rule(%Rule{} = rule, opts \\ []) do
    rule
    |> Repo.delete()
    |> audit(:deleted, Keyword.get(opts, :actor))
    |> broadcast()
  end

  @doc """
  Toggles a rule's enabled flag.
  """
  @spec toggle_rule(Rule.t()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def toggle_rule(%Rule{} = rule, opts \\ []) do
    action = if rule.enabled, do: :disabled, else: :enabled

    update_rule(rule, %{enabled: not rule.enabled}, Keyword.put(opts, :action, action))
  end

  @doc """
  Builds a changeset for a rule form.
  """
  @spec change_rule(Rule.t(), map()) :: Ecto.Changeset.t()
  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  @doc """
  Duplicates a rule, appending a suffix to its name.
  """
  @spec duplicate_rule(Rule.t(), String.t()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def duplicate_rule(%Rule{} = rule, suffix, opts \\ []) do
    rule
    |> Map.take([
      :description,
      :enabled,
      :priority,
      :game,
      :server_id,
      :trigger_event,
      :trigger_interval_seconds,
      :logical_operator,
      :cooldown_seconds,
      :max_executions_per_player,
      :escalation_window_seconds,
      :group
    ])
    |> Map.put(:name, "#{rule.name} #{suffix}")
    |> Map.put(:conditions, Enum.map(rule.conditions, &Map.from_struct/1))
    |> Map.put(:actions, Enum.map(rule.actions, &Map.from_struct/1))
    |> create_rule(Keyword.merge(opts, action: :duplicated))
  end

  # ── Import and export ──────────────────────────────────────────────────────

  @doc """
  Encodes rules as a portable JSON document.
  """
  @spec export_rules([Rule.t()]) :: String.t()
  def export_rules(rules), do: Transfer.encode(rules)

  @doc """
  Parses an export without writing anything, for previewing an import.
  """
  @spec preview_import(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def preview_import(json), do: Transfer.decode(json)

  @doc """
  Creates the rules described by an export.

  ## Options

    * `:server_id` - pin every imported rule to this server instead of leaving
      it fleet-wide
    * `:enabled` - override the imported `enabled` flag; importing disabled and
      reviewing before switching on is the safer habit

  Runs in a transaction: a file with one bad rule imports nothing, rather than
  leaving half a rule set behind.
  """
  @spec import_rules(String.t(), keyword()) ::
          {:ok, [Rule.t()]} | {:error, String.t()} | {:error, integer(), Ecto.Changeset.t()}
  def import_rules(json, opts \\ []) do
    with {:ok, attrs_list} <- Transfer.decode(json) do
      attrs_list
      |> Enum.map(&apply_import_opts(&1, opts))
      |> insert_all_rules()
    end
  end

  defp apply_import_opts(attrs, opts) do
    attrs
    |> maybe_put(opts, :server_id, "server_id")
    |> maybe_put(opts, :enabled, "enabled")
  end

  defp maybe_put(attrs, opts, key, string_key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(attrs, string_key, value)
      :error -> attrs
    end
  end

  defp insert_all_rules(attrs_list) do
    result =
      Repo.transaction(fn ->
        attrs_list
        |> Enum.with_index()
        |> Enum.reduce([], fn {attrs, index}, acc ->
          case %Rule{} |> Rule.changeset(attrs) |> Repo.insert() do
            {:ok, rule} -> [rule | acc]
            {:error, changeset} -> Repo.rollback({index, changeset})
          end
        end)
      end)

    case result do
      {:ok, rules} ->
        rules = Enum.reverse(rules)
        Phoenix.PubSub.broadcast(PubSub, @topic, {:rules_changed, nil})
        {:ok, rules}

      {:error, {index, changeset}} ->
        {:error, index, changeset}
    end
  end

  # ── Executions ─────────────────────────────────────────────────────────────

  @doc """
  Records that a rule fired.
  """
  @spec record_execution(map()) :: {:ok, Execution.t()} | {:error, Ecto.Changeset.t()}
  def record_execution(attrs) do
    %Execution{}
    |> Execution.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an execution record with the outcome of its actions.

  The row is inserted before the actions run so the cooldown check can see it;
  this fills in what actually happened.
  """
  @spec update_execution(Execution.t(), map()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t()}
  def update_execution(%Execution{} = execution, attrs) do
    execution
    |> Execution.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists executions, newest first.

  ## Options

    * `:server_id`, `:rule_id`, `:player_id`, `:status` - filters
    * `:limit` - defaults to 100
    * `:offset` - how many rows to skip, for paging
  """
  @spec list_executions_for(map() | nil, keyword()) :: [Execution.t()]
  def list_executions_for(user, opts \\ []) do
    user
    |> executions_query(opts)
    |> order_by([e], desc: e.executed_at, desc: e.id)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> preload([:rule, :server])
    |> Repo.all()
  end

  @doc """
  How many executions match, ignoring `:limit` and `:offset`.

  Paging needs the size of the whole set, not of the page: without it the
  history can only offer "next" and never says how much there is.
  """
  @spec count_executions_for(map() | nil, keyword()) :: non_neg_integer()
  def count_executions_for(user, opts \\ []) do
    user
    |> executions_query(opts)
    |> exclude(:order_by)
    |> select([e], count(e.id))
    |> Repo.one() || 0
  end

  @doc """
  Lists executions, newest first.
  """
  @spec list_executions(keyword()) :: [Execution.t()]
  def list_executions(opts \\ []), do: list_executions_for(nil, opts)

  # The filtered, permission-scoped set, before ordering and paging. `nil`
  # means "no user", which the scope helper treats as unrestricted - the
  # engine and the tests both call in without one.
  defp executions_query(user, opts) do
    Execution
    |> filter_executions(opts)
    |> scope_executions_to_user(user)
  end

  @doc """
  When a rule last fired for a player, or `nil` if it never has.

  Used by `HllConditionalActions.Engine.Limiter` for the cooldown check.
  """
  @spec last_executed_at(term(), String.t()) :: DateTime.t() | nil
  def last_executed_at(rule_id, player_id) do
    Repo.one(
      from e in Execution,
        where: e.rule_id == ^rule_id and e.player_id == ^player_id,
        select: max(e.executed_at)
    )
  end

  @doc """
  How many times a rule fired for a player since a point in time.

  Used for the per-player execution cap.
  """
  @spec count_executions_since(term(), String.t(), DateTime.t()) :: non_neg_integer()
  def count_executions_since(rule_id, player_id, since) do
    Repo.one(
      from e in Execution,
        where: e.rule_id == ^rule_id and e.player_id == ^player_id and e.executed_at >= ^since,
        select: count(e.id)
    )
  end

  @doc """
  What rule activity looks like for whatever the filters select, for an
  overview screen.

  Takes the same filters as `list_executions/1` (`:rule_id`, `:server_id`,
  `:player_id`, `:status`) and answers, in one place: how many times rules
  fired, how many of those were in the last 24 hours, how many distinct
  players were reached, the breakdown by outcome, and when the last one
  landed. Returned as a plain map so a page can render it without knowing
  any of the queries.

  ## Examples

      Rules.execution_stats(rule_id: rule.id)
      Rules.execution_stats(server_id: server.id)
  """
  @spec execution_stats(keyword()) :: %{
          total: non_neg_integer(),
          last_24h: non_neg_integer(),
          players: non_neg_integer(),
          by_status: %{atom() => non_neg_integer()},
          last_executed_at: DateTime.t() | nil
        }
  def execution_stats(filters) do
    since = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)
    scoped = filter_executions(Execution, filters)

    totals =
      Repo.one(
        from e in scoped,
          select: %{
            total: count(e.id),
            players: count(e.player_id, :distinct),
            last_executed_at: max(e.executed_at)
          }
      ) || %{total: 0, players: 0, last_executed_at: nil}

    last_24h =
      Repo.one(from e in scoped, where: e.executed_at >= ^since, select: count(e.id)) || 0

    by_status =
      Repo.all(from e in scoped, group_by: e.status, select: {e.status, count(e.id)})
      |> Map.new()

    Map.merge(totals, %{last_24h: last_24h, by_status: by_status})
  end

  @doc """
  Deletes execution records older than `days`, so the audit log stays bounded.
  """
  @spec prune_executions(pos_integer()) :: {non_neg_integer(), nil}
  def prune_executions(days) when days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
    Repo.delete_all(from e in Execution, where: e.executed_at < ^cutoff)
  end

  @doc """
  Other enabled rules that would fire on the same event as this one.

  Two rules on the same trigger and overlapping scope both run when that
  event arrives — which is legitimate (warn *and* log to Discord) and also
  the most common way an admin surprises themselves (two rules that both
  kick). The builder shows this as a heads up, never as an error: the engine
  is happy to run both, and only the person writing them knows whether that
  is what they meant.

  A fleet-wide rule overlaps every rule of the same game, and a pinned rule
  overlaps the fleet-wide ones plus those on its own server.
  """
  @spec overlapping_rules(Rule.t()) :: [Rule.t()]
  def overlapping_rules(%Rule{trigger_event: nil}), do: []

  def overlapping_rules(%Rule{} = rule) do
    Rule
    |> where([r], r.enabled == true)
    |> where([r], r.game == ^rule.game)
    |> where([r], r.trigger_event == ^rule.trigger_event)
    |> exclude_self(rule)
    |> overlapping_scope(rule)
    |> order_by([r], desc: r.priority, asc: r.name)
    |> limit(20)
    |> preload(:server)
    |> Repo.all()
  end

  defp exclude_self(query, %Rule{id: nil}), do: query
  defp exclude_self(query, %Rule{id: id}), do: where(query, [r], r.id != ^id)

  # A fleet-wide rule reaches every server of its game, so everything of that
  # game overlaps it.
  defp overlapping_scope(query, %Rule{server_id: nil}), do: query

  defp overlapping_scope(query, %Rule{server_id: id}) do
    where(query, [r], is_nil(r.server_id) or r.server_id == ^id)
  end

  @doc """
  The group names in use, for the filter and the builder's suggestions.
  """
  @spec list_groups(map() | nil) :: [String.t()]
  def list_groups(user \\ nil) do
    Rule
    |> scope_to_user(user)
    |> where([r], not is_nil(r.group) and r.group != "")
    |> distinct(true)
    |> order_by([r], asc: r.group)
    |> select([r], r.group)
    |> Repo.all()
  end

  @doc """
  Enables or disables every rule of a group at once.

  Returns how many rules moved. Each one is recorded in the audit trail
  individually, because "who disabled the whole seeding group" is exactly the
  question the history exists to answer.
  """
  @spec set_group_enabled(String.t(), boolean(), keyword()) :: non_neg_integer()
  def set_group_enabled(group, enabled?, opts \\ []) when is_binary(group) do
    Rule
    |> where([r], r.group == ^group and r.enabled != ^enabled?)
    |> Repo.all()
    |> Enum.count(fn rule ->
      match?({:ok, _rule}, toggle_rule(rule, opts))
    end)
  end

  # A user restricted to certain servers only sees rules that reach them.
  defp scope_to_user(query, nil), do: query

  defp scope_to_user(query, user) do
    case HllConditionalActions.Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [r], is_nil(r.server_id) or r.server_id in ^ids)
    end
  end

  @doc """
  The players a rule has acted on, newest first, for the player search.

  Searches the recorded player names rather than CRCON, so somebody who left
  an hour ago is still findable — which is exactly when an admin goes looking
  ("who was that guy who got kicked?").
  """
  @spec search_players(map() | nil, String.t(), keyword()) :: [
          %{player_id: String.t(), player_name: String.t() | nil, last_seen: DateTime.t()}
        ]
  def search_players(user, term, opts \\ []) when is_binary(term) do
    # The LIKE wildcards are stripped rather than escaped, so a term made only
    # of them is a search for nothing — not, as the bare pattern would have it,
    # a request for every player the app has ever touched.
    trimmed = term |> String.replace(~r/[%_]/, "") |> String.trim()

    if trimmed == "" do
      []
    else
      do_search_players(user, trimmed, opts)
    end
  end

  defp do_search_players(user, trimmed, opts) do
    pattern = "%" <> trimmed <> "%"

    Execution
    |> scope_executions_to_user(user)
    |> where([e], not is_nil(e.player_id))
    |> where([e], ilike(e.player_name, ^pattern) or e.player_id == ^trimmed)
    |> group_by([e], [e.player_id, e.player_name])
    |> order_by([e], desc: max(e.executed_at))
    |> limit(^Keyword.get(opts, :limit, 20))
    |> select([e], %{
      player_id: e.player_id,
      player_name: e.player_name,
      last_seen: max(e.executed_at)
    })
    |> Repo.all()
  end

  @doc """
  Which rules hit a player, how often, and when they last did.

  The player overview's core question: not "what happened" in general, but
  "what has this app been doing to this person".
  """
  @spec rules_for_player(String.t(), keyword()) :: [
          %{
            rule_id: term(),
            rule_name: String.t(),
            count: non_neg_integer(),
            last_executed_at: DateTime.t()
          }
        ]
  def rules_for_player(player_id, opts \\ []) do
    Execution
    |> join(:inner, [e], r in assoc(e, :rule))
    |> where([e], e.player_id == ^player_id)
    |> group_by([e, r], [r.id, r.name])
    |> order_by([e], desc: count(e.id))
    |> limit(^Keyword.get(opts, :limit, 20))
    |> select([e, r], %{
      rule_id: r.id,
      rule_name: r.name,
      count: count(e.id),
      last_executed_at: max(e.executed_at)
    })
    |> Repo.all()
  end

  # The same server scoping `list_executions_for/2` applies, as a query.
  defp scope_executions_to_user(query, user) do
    case HllConditionalActions.Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [e], e.server_id in ^ids)
    end
  end

  # ── Query helpers ──────────────────────────────────────────────────────────

  defp filter_rules(query, opts) do
    Enum.reduce(opts, query, fn
      {:game, game}, acc when not is_nil(game) -> where(acc, [r], r.game == ^game)
      {:server_id, id}, acc when not is_nil(id) -> where(acc, [r], r.server_id == ^id)
      {:enabled, value}, acc when is_boolean(value) -> where(acc, [r], r.enabled == ^value)
      {:trigger_event, t}, acc when not is_nil(t) -> where(acc, [r], r.trigger_event == ^t)
      {:group, g}, acc when is_binary(g) and g != "" -> where(acc, [r], r.group == ^g)
      {:search, term}, acc when is_binary(term) and term != "" -> search_rules(acc, term)
      _other, acc -> acc
    end)
  end

  # Name and description, case insensitively. A fleet grows past the point
  # where the filters alone find the rule you mean.
  defp search_rules(query, term) do
    pattern = "%" <> String.replace(term, ~r/[%_]/, "") <> "%"

    where(query, [r], ilike(r.name, ^pattern) or ilike(r.description, ^pattern))
  end

  defp filter_executions(query, opts) do
    Enum.reduce(opts, query, fn
      {:server_id, id}, acc when not is_nil(id) -> where(acc, [e], e.server_id == ^id)
      {:rule_id, id}, acc when not is_nil(id) -> where(acc, [e], e.rule_id == ^id)
      {:player_id, id}, acc when not is_nil(id) -> where(acc, [e], e.player_id == ^id)
      {:status, status}, acc when not is_nil(status) -> where(acc, [e], e.status == ^status)
      _other, acc -> acc
    end)
  end

  defp broadcast({:ok, rule} = result) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {:rules_changed, rule})
    result
  end

  defp broadcast(result), do: result

  # Recording is best effort and never changes the caller's result.
  defp audit(result, action, actor, changeset \\ nil)

  defp audit({:ok, %Rule{} = rule} = result, action, actor, changeset) do
    Audit.record(rule, action, actor, changeset)
    result
  end

  defp audit(result, _action, _actor, _changeset), do: result
end
