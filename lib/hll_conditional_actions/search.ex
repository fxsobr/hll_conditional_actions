defmodule HllConditionalActions.Search do
  @moduledoc """
  The global search behind the command palette (Ctrl K): players, rules,
  tickets and past matches, each scoped to what the signed in user may see.

  Players are whoever this install recorded - the running totals kept at
  every match end, the players a rule acted on and the ones who opened a
  ticket - found by any name they were recorded under or by their ID.
  Rules match on their name and description, and also come back when they
  acted on one of the players found ("rules that mention"). Tickets match on
  their number, the players on them and their conversation.

  Past matches live in CRCON, not here: `matches/3` filters a page of each
  server's history the caller already fetched with `recent_matches/1`, so a
  palette asks CRCON once per opening instead of once per keystroke.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Matches
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Tickets.Message
  alias HllConditionalActions.Tickets.Ticket

  @limit 5

  @type player :: %{
          id: String.t(),
          name: String.t() | nil,
          seen_at: DateTime.t() | nil,
          server_id: term(),
          hits: non_neg_integer(),
          tickets: non_neg_integer(),
          matches: non_neg_integer()
        }

  @doc """
  The search term a query stands for: trimmed, without the LIKE wildcards,
  or nil when nothing is left to look for.

      iex> HllConditionalActions.Search.term("  rudi% ")
      "rudi"
      iex> HllConditionalActions.Search.term("%_")
      nil
  """
  @spec term(String.t() | nil) :: String.t() | nil
  def term(nil), do: nil

  def term(query) when is_binary(query) do
    case query |> String.replace(~r/[%_\\]/, "") |> String.trim() |> String.slice(0, 80) do
      "" -> nil
      term -> term
    end
  end

  # ── Players ────────────────────────────────────────────────────────────────

  @doc """
  Players recorded under a name containing `term`, or with that exact ID,
  the most recently seen first.
  """
  @spec players(map() | nil, String.t() | nil, pos_integer()) :: [player()]
  def players(user, term, limit \\ @limit)
  def players(_user, nil, _limit), do: []

  def players(user, term, limit) do
    if Accounts.can?(user, :view_stats) do
      pattern = "%" <> term <> "%"

      totals =
        PlayerTotal
        |> scoped(user)
        |> where([p], ilike(p.player_name, ^pattern) or p.player_id == ^term)
        |> group_by([p], p.player_id)
        |> select([p], %{
          id: p.player_id,
          name: max(p.player_name),
          seen_at: max(p.updated_at),
          matches: sum(p.matches)
        })
        |> limit(50)
        |> Repo.all()

      hits =
        Execution
        |> scoped(user)
        |> where([e], not is_nil(e.player_id))
        |> where([e], ilike(e.player_name, ^pattern) or e.player_id == ^term)
        |> group_by([e], e.player_id)
        |> select([e], %{
          id: e.player_id,
          name: max(e.player_name),
          seen_at: max(e.executed_at),
          hits: count(e.id)
        })
        |> limit(50)
        |> Repo.all()

      tickets =
        if Accounts.can?(user, :view_tickets) do
          Ticket
          |> scoped(user)
          |> where([t], not is_nil(t.player_id))
          |> where([t], ilike(t.player_name, ^pattern) or t.player_id == ^term)
          |> group_by([t], t.player_id)
          |> select([t], %{
            id: t.player_id,
            name: max(t.player_name),
            seen_at: max(t.inserted_at),
            tickets: count(t.id)
          })
          |> limit(50)
          |> Repo.all()
        else
          []
        end

      (totals ++ hits ++ tickets)
      |> Enum.group_by(& &1.id)
      |> Enum.map(fn {id, rows} -> merge_player(id, rows) end)
      |> Enum.sort_by(&{rank(&1.name, term), -unix(&1.seen_at)})
      |> Enum.take(limit)
      |> with_last_server(user)
    else
      []
    end
  end

  defp merge_player(id, rows) do
    latest = Enum.max_by(rows, &unix(&1.seen_at))

    %{
      id: id,
      name: latest.name || Enum.find_value(rows, & &1.name),
      seen_at: to_utc(latest.seen_at),
      server_id: nil,
      hits: rows |> Enum.map(&Map.get(&1, :hits, 0)) |> Enum.sum(),
      tickets: rows |> Enum.map(&Map.get(&1, :tickets, 0)) |> Enum.sum(),
      matches: rows |> Enum.map(&(Map.get(&1, :matches) || 0)) |> Enum.sum()
    }
  end

  # An exact name first, then names that start with the term.
  defp rank(nil, _term), do: 3

  defp rank(name, term) do
    name = String.downcase(name)
    term = String.downcase(term)

    cond do
      name == term -> 0
      String.starts_with?(name, term) -> 1
      true -> 2
    end
  end

  # Where each player was last seen: the server of their newest record.
  defp with_last_server([], _user), do: []

  defp with_last_server(players, user) do
    ids = Enum.map(players, & &1.id)

    totals =
      PlayerTotal
      |> scoped(user)
      |> where([p], p.player_id in ^ids)
      |> select([p], {p.player_id, p.server_id, p.updated_at})
      |> Repo.all()

    executions =
      Execution
      |> scoped(user)
      |> where([e], e.player_id in ^ids)
      |> distinct([e], e.player_id)
      |> order_by([e], asc: e.player_id, desc: e.executed_at)
      |> select([e], {e.player_id, e.server_id, e.executed_at})
      |> Repo.all()

    last =
      (totals ++ executions)
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {id, rows} -> {id, rows |> Enum.max_by(&unix(elem(&1, 2))) |> elem(1)} end)

    Enum.map(players, &%{&1 | server_id: Map.get(last, &1.id)})
  end

  # ── Rules ──────────────────────────────────────────────────────────────────

  @doc """
  Rules whose name or description contains `term`, then the rules that
  acted on `player_ids`, each with `hits` - how many times it acted on
  them - and `player` - which of them it hit most.
  """
  @spec rules(map() | nil, String.t() | nil, [String.t()], pos_integer()) :: [map()]
  def rules(user, term, player_ids \\ [], limit \\ @limit)
  def rules(_user, nil, _player_ids, _limit), do: []

  def rules(user, term, player_ids, limit) do
    if Accounts.can?(user, :view_rules) do
      needle = String.downcase(term)
      rules = Rules.list_rules_for(user)

      named =
        rules
        |> Enum.filter(fn rule ->
          String.contains?(String.downcase(rule.name || ""), needle) or
            String.contains?(String.downcase(rule.description || ""), needle)
        end)
        |> Enum.map(&%{rule: &1, hits: 0, player_id: nil})

      by_id = Map.new(rules, &{&1.id, &1})

      hitting =
        player_ids
        |> rule_hits(user)
        |> Enum.flat_map(&rule_hit(&1, by_id))

      (named ++ hitting)
      |> Enum.uniq_by(& &1.rule.id)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp rule_hit({rule_id, player_id, hits}, by_id) do
    case by_id[rule_id] do
      nil -> []
      rule -> [%{rule: rule, hits: hits, player_id: player_id}]
    end
  end

  defp rule_hits([], _user), do: []

  defp rule_hits(player_ids, user) do
    user
    |> Rules.scoped_executions()
    |> where([e], e.player_id in ^player_ids)
    |> group_by([e], [e.rule_id, e.player_id])
    |> select([e], {e.rule_id, e.player_id, count(e.id)})
    |> Repo.all()
    |> Enum.sort_by(&(-elem(&1, 2)))
  end

  # ── Tickets ────────────────────────────────────────────────────────────────

  @doc """
  Tickets with that number, about a player whose name contains `term`, or
  whose conversation does, the most recently active first. Each comes with
  `snippet`, the line of the conversation that matched.
  """
  @spec tickets(map() | nil, String.t() | nil, pos_integer()) :: [map()]
  def tickets(user, term, limit \\ @limit)
  def tickets(_user, nil, _limit), do: []

  def tickets(user, term, limit) do
    if Accounts.can?(user, :view_tickets) do
      pattern = "%" <> term <> "%"

      said =
        from m in Message,
          where: m.author in [:player, :admin] and ilike(m.body, ^pattern),
          select: m.ticket_id

      named =
        dynamic(
          [t],
          ilike(t.player_name, ^pattern) or ilike(t.reported_player_name, ^pattern) or
            t.player_id == ^term or t.id in subquery(said)
        )

      matching =
        case Integer.parse(String.trim_leading(term, "#")) do
          {id, ""} -> dynamic([t], t.id == ^id or ^named)
          _other -> named
        end

      tickets =
        Ticket
        |> scoped(user)
        |> where(^matching)
        |> order_by([t], desc: t.last_activity_at, desc: t.id)
        |> limit(^limit)
        |> preload([:server, :closed_by])
        |> Repo.all()

      snippets = snippets(Enum.map(tickets, & &1.id), pattern)
      Enum.map(tickets, &%{ticket: &1, snippet: snippets[&1.id]})
    else
      []
    end
  end

  defp snippets([], _pattern), do: %{}

  defp snippets(ids, pattern) do
    Message
    |> where([m], m.ticket_id in ^ids and m.author in [:player, :admin])
    |> where([m], ilike(m.body, ^pattern))
    |> order_by([m], asc: m.id)
    |> select([m], {m.ticket_id, m.body})
    |> Repo.all()
    |> Enum.reverse()
    |> Map.new()
  end

  # ── Matches ────────────────────────────────────────────────────────────────

  @doc """
  A page of recent matches of each server, from CRCON, for `matches/3` to
  filter. A server that does not answer is left out.
  """
  @spec recent_matches([map()]) :: [map()]
  def recent_matches(servers) do
    servers
    |> Task.async_stream(
      fn server ->
        case Matches.list(server, limit: 50) do
          {:ok, %{matches: matches}} -> Enum.map(matches, &Map.put(&1, :server, server))
          _error -> []
        end
      end,
      timeout: 8_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, matches} -> matches
      _timeout -> []
    end)
  end

  @doc """
  The matches of `recent` played on a map whose name contains `term`, or
  with that ID, newest first.
  """
  @spec matches([map()], String.t() | nil, pos_integer()) :: [map()]
  def matches(recent, term, limit \\ @limit)
  def matches(_recent, nil, _limit), do: []

  def matches(recent, term, limit) do
    needle = String.downcase(term)
    number = String.trim_leading(term, "#")

    recent
    |> Enum.filter(fn match ->
      String.contains?(String.downcase(match.map || ""), needle) or
        to_string(match.id) == number
    end)
    |> Enum.sort_by(&(-unix(&1.started_at)))
    |> Enum.take(limit)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp scoped(query, user) do
    case Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [x], x.server_id in ^ids)
    end
  end

  defp unix(nil), do: 0
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  defp unix(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp to_utc(other), do: other
end
