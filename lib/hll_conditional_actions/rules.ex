defmodule HllConditionalActions.Rules do
  @moduledoc """
  Manages conditional rules and their execution history.

  Rule changes are broadcast on `"rules"` so every running
  `HllConditionalActions.Engine.Runner` can reload without polling the
  database on each game event.
  """

  import Ecto.Query

  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Audit
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Rules.Snapshot
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

  # What a new install is most likely to reach for, before any rule exists
  # to learn from.
  @curated_fields [
    :player_level,
    :teamkills,
    :is_vip,
    :player_team,
    :server_player_count,
    :kills
  ]

  @doc """
  The condition fields used most across every rule, most used first, for the
  top of the builder's field picker. `:always_true` is never counted; with
  no rule to learn from, a curated list stands in.
  """
  @spec most_used_fields(pos_integer()) :: [atom()]
  def most_used_fields(limit \\ 6) do
    used =
      Rule
      |> select([r], r.conditions)
      |> Repo.all()
      |> List.flatten()
      |> Enum.map(& &1.field)
      |> Enum.reject(&(&1 in [nil, :always_true]))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {field, count} -> {-count, field} end)
      |> Enum.map(fn {field, _count} -> field end)

    case used do
      [] -> Enum.take(@curated_fields, limit)
      fields -> Enum.take(fields, limit)
    end
  end

  @doc """
  Players this install has seen, as `{player_id, player_name}` pairs, most
  recently seen first - for autocompleting ids and names in the builder.
  """
  @spec known_players(pos_integer()) :: [{String.t(), String.t()}]
  def known_players(limit \\ 300) do
    PlayerTotal
    |> where([p], not is_nil(p.player_name))
    |> group_by([p], p.player_id)
    |> order_by([p], desc: max(p.updated_at))
    |> select([p], {p.player_id, max(p.player_name)})
    |> limit(^limit)
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

  # Only when the caller sent a group: attrs may use atom or string keys.
  defp canonicalize_group(attrs) do
    Enum.reduce([:group, "group"], attrs, fn key, acc ->
      case acc do
        %{^key => value} when is_binary(value) ->
          Map.put(acc, key, canonical_group(value, list_groups()) || "")

        _other ->
          acc
      end
    end)
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
    attrs = canonicalize_group(attrs)

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
    changeset = Rule.changeset(rule, canonicalize_group(attrs))

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
  Pauses a rule until a moment in the future.

  The rule stays enabled; the engine skips it until `until` has passed and
  then picks it up again by itself. Recorded in the change history as
  `:paused`.
  """
  @spec pause_rule(Rule.t(), DateTime.t(), keyword()) ::
          {:ok, Rule.t()} | {:error, Ecto.Changeset.t() | :in_the_past}
  def pause_rule(%Rule{} = rule, %DateTime{} = until, opts \\ []) do
    if DateTime.compare(until, DateTime.utc_now()) == :gt do
      changeset = Rule.pause_changeset(rule, until, Keyword.get(opts, :reason))

      changeset
      |> Repo.update()
      |> audit(:paused, Keyword.get(opts, :actor), changeset)
      |> broadcast()
    else
      {:error, :in_the_past}
    end
  end

  @doc """
  Ends a pause right away.
  """
  @spec resume_rule(Rule.t(), keyword()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def resume_rule(%Rule{} = rule, opts \\ []) do
    changeset = Rule.pause_changeset(rule, nil, nil)

    changeset
    |> Repo.update()
    |> audit(:resumed, Keyword.get(opts, :actor), changeset)
    |> broadcast()
  end

  # ── Drafts ─────────────────────────────────────────────────────────────────

  @doc """
  Whether edits to this rule should go to a draft rather than straight to the
  engine: only a live (enabled) rule has anything to protect.
  """
  @spec draft_required?(Rule.t()) :: boolean()
  def draft_required?(%Rule{id: id, enabled: enabled}), do: not is_nil(id) and enabled == true

  @doc """
  Saves `attrs` as the rule's pending draft without touching what the engine
  runs. The attributes are validated exactly as a save would validate them,
  so a draft can always be published unless the world changed under it.
  """
  @spec save_draft(Rule.t(), map(), keyword()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def save_draft(%Rule{} = rule, attrs, opts \\ []) do
    changeset = Rule.changeset(rule, canonicalize_group(attrs))

    if changeset.valid? do
      snapshot = changeset |> Ecto.Changeset.apply_changes() |> Snapshot.take()
      actor = Keyword.get(opts, :actor)

      rule
      |> Ecto.Changeset.change(
        draft: snapshot,
        draft_user_name: actor && (Map.get(actor, :name) || Map.get(actor, :username)),
        draft_updated_at: DateTime.utc_now(:second)
      )
      |> Repo.update()
      |> broadcast()
    else
      {:error, Map.put(changeset, :action, :update)}
    end
  end

  @doc """
  Throws away a rule's draft.
  """
  @spec discard_draft(Rule.t()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def discard_draft(%Rule{} = rule) do
    rule
    |> Ecto.Changeset.change(draft: nil, draft_user_name: nil, draft_updated_at: nil)
    |> Repo.update()
    |> broadcast()
  end

  @doc """
  Applies `attrs` to the rule the engine runs, clears any draft and records
  the change as published.
  """
  @spec publish(Rule.t(), map(), keyword()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def publish(%Rule{} = rule, attrs, opts \\ []) do
    changeset =
      rule
      |> Rule.changeset(canonicalize_group(attrs))
      |> Ecto.Changeset.change(draft: nil, draft_user_name: nil, draft_updated_at: nil)

    changeset
    |> Repo.update()
    |> audit(:published, Keyword.get(opts, :actor), changeset)
    |> broadcast()
  end

  @doc """
  Publishes the rule's pending draft.
  """
  @spec publish_draft(Rule.t(), keyword()) ::
          {:ok, Rule.t()} | {:error, Ecto.Changeset.t() | :no_draft}
  def publish_draft(rule, opts \\ [])
  def publish_draft(%Rule{draft: nil}, _opts), do: {:error, :no_draft}
  def publish_draft(%Rule{draft: draft} = rule, opts), do: publish(rule, draft, opts)

  @doc """
  Loads a version's snapshot as the rule's draft, to be reviewed and
  published. Versions recorded before snapshots existed cannot be restored.
  """
  @spec restore_version(Rule.t(), term(), keyword()) ::
          {:ok, Rule.t()} | {:error, Ecto.Changeset.t() | :not_restorable}
  def restore_version(%Rule{} = rule, version_id, opts \\ []) do
    case Audit.get_version(rule.id, version_id) do
      %{snapshot: snapshot} when is_map(snapshot) -> save_draft(rule, snapshot, opts)
      _other -> {:error, :not_restorable}
    end
  end

  @doc """
  Activity per rule for the rules list, as `%{rule_id => stats}`, in one
  grouped query: when it last fired, how many times in the last 24 hours and
  how many of those failed.
  """
  @spec activity_for_rules([term()]) :: %{
          term() => %{
            last_executed_at: DateTime.t() | nil,
            last_24h: non_neg_integer(),
            failed_24h: non_neg_integer()
          }
        }
  def activity_for_rules([]), do: %{}

  def activity_for_rules(rule_ids) do
    since = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    from(e in Execution,
      where: e.rule_id in ^rule_ids,
      group_by: e.rule_id,
      select: {
        e.rule_id,
        %{
          last_executed_at: max(e.executed_at),
          last_24h: filter(count(e.id), e.executed_at >= ^since),
          failed_24h: filter(count(e.id), e.executed_at >= ^since and e.status == ^:failed)
        }
      }
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Resolves a typed group name against the groups already in use: trims and
  collapses whitespace, and reuses an existing group that differs only in
  case, so "seeding" joins "Seeding" instead of starting a new folder.
  """
  @spec canonical_group(term(), [String.t()]) :: String.t() | nil
  def canonical_group(group, existing) do
    case Rule.normalize_group(group) do
      nil ->
        nil

      name ->
        down = String.downcase(name)
        Enum.find(existing, name, &(String.downcase(&1) == down))
    end
  end

  @doc """
  Builds a changeset for a rule form.
  """
  @spec change_rule(Rule.t(), map()) :: Ecto.Changeset.t()
  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  @doc """
  Duplicates a rule, appending a suffix to its name.

  With `server_id:` the copy is pinned to that server instead, for taking a
  rule that works on one server to another. Such a copy arrives disabled: it
  has never run there, and switching it on is a decision for the admin of
  that server, not a side effect of copying.
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
    |> Map.put(:name, String.trim("#{rule.name} #{suffix}"))
    |> Map.put(:conditions, Enum.map(rule.conditions, &Map.from_struct/1))
    |> Map.put(:actions, Enum.map(rule.actions, &Map.from_struct/1))
    |> Map.put(:exemptions, rule.exemptions && Map.from_struct(rule.exemptions))
    |> retarget(opts[:server_id])
    |> create_rule(opts |> Keyword.delete(:server_id) |> Keyword.merge(action: :duplicated))
  end

  defp retarget(attrs, nil), do: attrs
  defp retarget(attrs, server_id), do: %{attrs | server_id: server_id, enabled: false}

  @doc """
  The servers a rule can be copied to: those of the same game the user may
  manage, other than the one it is already on.
  """
  @spec copy_targets(Rule.t(), [Server.t()]) :: [Server.t()]
  def copy_targets(%Rule{} = rule, servers) do
    Enum.filter(servers, &(&1.game == rule.game and &1.id != rule.server_id))
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

  # The index rides along so a failure can say which rule of the batch it was.
  defp insert_or_rollback({attrs, index}, inserted) do
    case %Rule{} |> Rule.changeset(attrs) |> Repo.insert() do
      {:ok, rule} -> [rule | inserted]
      {:error, changeset} -> Repo.rollback({index, changeset})
    end
  end

  defp insert_all_rules(attrs_list) do
    result =
      Repo.transaction(fn ->
        attrs_list
        |> Enum.with_index()
        |> Enum.reduce([], &insert_or_rollback/2)
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

  @doc """
  Every execution the user may see, as a query to build reports on.
  """
  @spec scoped_executions(map() | nil) :: Ecto.Query.t()
  def scoped_executions(user) do
    Execution
    |> from()
    |> scope_executions_to_user(user)
  end

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
  The executions of a rule for a player inside `[from, to)`, oldest first.

  Used to replay the limits as they stood when a past event arrived.
  """
  @spec executions_between(term(), String.t(), DateTime.t(), DateTime.t()) :: [Execution.t()]
  def executions_between(rule_id, player_id, from, to) do
    Repo.all(
      from e in Execution,
        where:
          e.rule_id == ^rule_id and e.player_id == ^player_id and e.executed_at >= ^from and
            e.executed_at < ^to,
        order_by: [asc: e.executed_at]
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

  @doc """
  Applies one change to many rules, for the list's bulk actions.

  Each rule goes through the same function a single change would, so every
  one is validated, audited and broadcast on its own; the history then says
  who disabled which rule, not that "something bulk happened". Returns how
  many rules actually changed.

  Operations:

    * `{:enabled, boolean}` - switches rules on or off, skipping those
      already in that state
    * `{:group, name}` - moves rules into a group (`""` or `nil` takes them
      out of any group)
    * `:delete` - removes the rules and their history
  """
  @spec bulk_update(
          [Rule.t()],
          {:enabled, boolean()} | {:group, String.t() | nil} | :delete,
          keyword()
        ) :: non_neg_integer()
  def bulk_update(rules, operation, opts \\ [])

  def bulk_update(rules, {:enabled, enabled?}, opts) when is_boolean(enabled?) do
    rules
    |> Enum.reject(&(&1.enabled == enabled?))
    |> Enum.count(&match?({:ok, _rule}, toggle_rule(&1, opts)))
  end

  def bulk_update(rules, {:group, group}, opts) do
    group = canonical_group(group, list_groups()) || ""

    rules
    |> Enum.reject(&((&1.group || "") == group))
    |> Enum.count(&match?({:ok, _rule}, update_rule(&1, %{group: group}, opts)))
  end

  def bulk_update(rules, :delete, opts) do
    Enum.count(rules, &match?({:ok, _rule}, delete_rule(&1, opts)))
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
      {:game, game}, acc when not is_nil(game) ->
        where(acc, [r], r.game == ^game)

      {:server_id, id}, acc when not is_nil(id) ->
        where(acc, [r], r.server_id == ^id)

      # What runs on a server: its own rules and the fleet wide ones of its game.
      {:applies_to, %Server{id: id, game: game}}, acc ->
        where(acc, [r], r.server_id == ^id or (is_nil(r.server_id) and r.game == ^game))

      {:enabled, value}, acc when is_boolean(value) ->
        where(acc, [r], r.enabled == ^value)

      {:trigger_event, t}, acc when not is_nil(t) ->
        where(acc, [r], r.trigger_event == ^t)

      {:group, g}, acc when is_binary(g) and g != "" ->
        where(acc, [r], r.group == ^g)

      {:ids, ids}, acc when is_list(ids) ->
        where(acc, [r], r.id in ^ids)

      {:search, term}, acc when is_binary(term) and term != "" ->
        search_rules(acc, term)

      _other, acc ->
        acc
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
      {:player, term}, acc when is_binary(term) and term != "" -> search_player(acc, term)
      {:status, status}, acc when not is_nil(status) -> where(acc, [e], e.status == ^status)
      {:from, %DateTime{} = from}, acc -> where(acc, [e], e.executed_at >= ^from)
      {:until, %DateTime{} = until}, acc -> where(acc, [e], e.executed_at <= ^until)
      _other, acc -> acc
    end)
  end

  # A player filter matches the exact ID or part of the recorded name, so an
  # admin can paste either. LIKE wildcards are stripped, as in the search.
  defp search_player(query, term) do
    trimmed = String.trim(term)
    pattern = "%" <> String.replace(trimmed, ~r/[%_]/, "") <> "%"

    where(query, [e], e.player_id == ^trimmed or ilike(e.player_name, ^pattern))
  end

  defp broadcast({:ok, rule} = result) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {:rules_changed, rule})
    HllConditionalActions.Attention.notify_changed()
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
