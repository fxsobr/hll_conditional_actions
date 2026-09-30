defmodule HllConditionalActions.Players.Directory do
  @moduledoc """
  The player list: everybody this install knows, one row per player.

  "Knows" joins what CRCON remembers (`Players.Profile`, the directory kept
  from its player history and live lists) with what the app recorded
  itself: the running totals of every match end (`player_totals`), the
  players a rule acted on (`rule_executions`) and, for whoever may see
  them, the players of tickets. Each source is grouped per player, then the
  four are joined on the player ID, so one player is one row.

  Everything is scoped to the servers the user may see. The sets that live
  in CRCON rather than here - who is online, VIP or watched - come in as
  lists of IDs (`:sets`), read once per server by
  `HllConditionalActions.Players`.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Players.Profile
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Execution
  alias HllConditionalActions.Tickets.Ticket

  @filters ~w(all online vip watchlist penalties new matches rules tickets)
  @sorts ~w(seen playtime penalties rules name)

  @doc "The filters the list understands."
  @spec filters() :: [String.t()]
  def filters, do: @filters

  @doc "The orders the list understands."
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts

  @typedoc """
  Options: `:query` (a name or ID), `:filter`, `:sort`, `:tickets?` (may
  the user see tickets), `:sets` (`%{online: ids, vip: ids, watchlist: ids}`),
  `:found` (IDs a CRCON search found), `:limit`, `:offset`.
  """
  @type opts :: keyword()

  @doc "A page of players."
  @spec list(map() | nil, opts()) :: [map()]
  def list(user, opts) do
    user
    |> joined(opts)
    |> where(^condition(Keyword.get(opts, :filter, "all"), opts))
    |> order(Keyword.get(opts, :sort, "seen"), online_ids(opts))
    |> limit(^Keyword.get(opts, :limit, 50))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> select([i, t, h, k, p], %{
      id: i.player_id,
      name: fragment("COALESCE(?, ?, ?, ?)", p.name, t.name, h.name, k.name),
      matches: coalesce(t.matches, 0),
      kills: coalesce(t.kills, 0),
      deaths: coalesce(t.deaths, 0),
      playtime: fragment("COALESCE(?, ?, 0)", p.playtime_seconds, t.playtime),
      sessions: p.sessions,
      penalties: coalesce(p.penalties, 0),
      level: p.level,
      clan_tag: p.clan_tag,
      flags: p.flags,
      hits: coalesce(h.hits, 0),
      tickets: coalesce(k.tickets, 0),
      open_tickets: coalesce(k.open, 0),
      first_seen:
        type(
          fragment(
            "COALESCE(?, LEAST(?, ?, ?))",
            p.first_seen_at,
            t.first_at,
            h.first_at,
            k.first_at
          ),
          :naive_datetime_usec
        ),
      seen_at:
        type(
          fragment("GREATEST(?, ?, ?, ?)", p.last_seen_at, t.seen_at, h.seen_at, k.seen_at),
          :naive_datetime_usec
        )
    })
    |> Repo.all()
  end

  @doc "How many players each filter holds, under the same search."
  @spec counts(map() | nil, opts()) :: %{String.t() => non_neg_integer()}
  def counts(user, opts) do
    sets = Keyword.get(opts, :sets, %{})
    online = Map.get(sets, :online, [])
    vip = Map.get(sets, :vip, [])
    watched = Map.get(sets, :watchlist, [])
    week_ago = week_ago()

    user
    |> joined(opts)
    |> select([i, t, h, k, p], %{
      "all" => count(i.player_id),
      "online" => filter(count(i.player_id), i.player_id in ^online),
      "vip" => filter(count(i.player_id), i.player_id in ^vip),
      "watchlist" => filter(count(i.player_id), i.player_id in ^watched),
      "penalties" => filter(count(i.player_id), p.penalties > 0),
      "new" =>
        filter(
          count(i.player_id),
          fragment(
            "COALESCE(?, LEAST(?, ?, ?)) >= ?",
            p.first_seen_at,
            t.first_at,
            h.first_at,
            k.first_at,
            ^week_ago
          )
        ),
      "matches" => filter(count(i.player_id), not is_nil(t.player_id)),
      "rules" => filter(count(i.player_id), not is_nil(h.player_id)),
      "tickets" => filter(count(i.player_id), not is_nil(k.player_id))
    })
    |> Repo.one()
  end

  defp joined(user, opts) do
    term = search_term(Keyword.get(opts, :query, ""))
    found = Keyword.get(opts, :found, [])
    tickets? = Keyword.get(opts, :tickets?, false)

    from i in subquery(player_ids(user, term, found, tickets?)),
      left_join: t in subquery(totals(user)),
      on: t.player_id == i.player_id,
      left_join: h in subquery(hits(user)),
      on: h.player_id == i.player_id,
      left_join: k in subquery(tickets(user, tickets?)),
      on: k.player_id == i.player_id,
      left_join: p in subquery(profiles(user)),
      on: p.player_id == i.player_id
  end

  # Every player ID any source knows, narrowed by the search. The search runs
  # on every name each source recorded, so a player found by an old name
  # still shows up; `found` adds the ones a CRCON search turned up (their
  # profiles were just remembered).
  defp player_ids(user, term, found, tickets?) do
    totals =
      PlayerTotal |> scoped(user) |> named(term) |> select([x], %{player_id: x.player_id})

    hits =
      Execution
      |> scoped(user)
      |> where([x], not is_nil(x.player_id))
      |> named(term)
      |> select([x], %{player_id: x.player_id})

    known =
      Profile
      |> profile_scoped(user)
      |> profile_named(term, found)
      |> select([x], %{player_id: x.player_id})

    ids = totals |> union(^hits) |> union(^known)

    if tickets? do
      tickets =
        Ticket
        |> scoped(user)
        |> where([x], not is_nil(x.player_id))
        |> named(term)
        |> select([x], %{player_id: x.player_id})

      union(ids, ^tickets)
    else
      ids
    end
  end

  defp totals(user) do
    PlayerTotal
    |> scoped(user)
    |> group_by([p], p.player_id)
    |> select([p], %{
      player_id: p.player_id,
      name: max(p.player_name),
      matches: sum(p.matches),
      kills: sum(p.kills),
      deaths: sum(p.deaths),
      playtime: sum(p.playtime_seconds),
      seen_at: max(p.updated_at),
      first_at: min(p.inserted_at)
    })
  end

  defp hits(user) do
    Execution
    |> scoped(user)
    |> where([e], not is_nil(e.player_id))
    |> group_by([e], e.player_id)
    |> select([e], %{
      player_id: e.player_id,
      name: max(e.player_name),
      hits: count(e.id),
      seen_at: max(e.executed_at),
      first_at: min(e.executed_at)
    })
  end

  defp tickets(user, tickets?) do
    Ticket
    |> scoped(user)
    |> where([t], not is_nil(t.player_id))
    |> then(fn query -> if tickets?, do: query, else: where(query, [t], false) end)
    |> group_by([t], t.player_id)
    |> select([t], %{
      player_id: t.player_id,
      name: max(t.player_name),
      tickets: count(t.id),
      open: filter(count(t.id), t.status != :closed),
      seen_at: max(t.inserted_at),
      first_at: min(t.inserted_at)
    })
  end

  defp profiles(user), do: Profile |> profile_scoped(user)

  defp condition("online", opts), do: in_set(opts, :online)
  defp condition("vip", opts), do: in_set(opts, :vip)
  defp condition("watchlist", opts), do: in_set(opts, :watchlist)
  defp condition("penalties", _opts), do: dynamic([i, t, h, k, p], p.penalties > 0)
  defp condition("matches", _opts), do: dynamic([i, t], not is_nil(t.player_id))
  defp condition("rules", _opts), do: dynamic([i, t, h], not is_nil(h.player_id))
  defp condition("tickets", _opts), do: dynamic([i, t, h, k], not is_nil(k.player_id))

  defp condition("new", _opts) do
    week_ago = week_ago()

    dynamic(
      [i, t, h, k, p],
      fragment(
        "COALESCE(?, LEAST(?, ?, ?)) >= ?",
        p.first_seen_at,
        t.first_at,
        h.first_at,
        k.first_at,
        ^week_ago
      )
    )
  end

  defp condition(_all, _opts), do: dynamic(true)

  defp in_set(opts, key) do
    ids = opts |> Keyword.get(:sets, %{}) |> Map.get(key, [])
    dynamic([i], i.player_id in ^ids)
  end

  defp online_ids(opts), do: opts |> Keyword.get(:sets, %{}) |> Map.get(:online, [])

  defp order(query, "seen", online) do
    order_by(query, [i, t, h, k, p],
      desc: fragment("? = ANY(?)", i.player_id, type(^online, {:array, :string})),
      desc_nulls_last:
        fragment("GREATEST(?, ?, ?, ?)", p.last_seen_at, t.seen_at, h.seen_at, k.seen_at),
      asc: i.player_id
    )
  end

  defp order(query, sort, _online), do: order(query, sort)

  defp order(query, "playtime") do
    order_by(query, [i, t, h, k, p],
      desc: fragment("COALESCE(?, ?, 0)", p.playtime_seconds, t.playtime),
      asc: i.player_id
    )
  end

  defp order(query, "penalties") do
    order_by(query, [i, t, h, k, p],
      desc: coalesce(p.penalties, 0),
      desc_nulls_last:
        fragment("GREATEST(?, ?, ?, ?)", p.last_seen_at, t.seen_at, h.seen_at, k.seen_at),
      asc: i.player_id
    )
  end

  defp order(query, "rules") do
    order_by(query, [i, t, h], desc: coalesce(h.hits, 0), asc: i.player_id)
  end

  defp order(query, "name") do
    order_by(query, [i, t, h, k, p],
      asc: fragment("lower(COALESCE(?, ?, ?, ?))", p.name, t.name, h.name, k.name),
      asc: i.player_id
    )
  end

  defp order(query, _seen) do
    order_by(query, [i, t, h, k, p],
      desc_nulls_last:
        fragment("GREATEST(?, ?, ?, ?)", p.last_seen_at, t.seen_at, h.seen_at, k.seen_at),
      asc: i.player_id
    )
  end

  defp week_ago do
    DateTime.utc_now() |> DateTime.add(-7 * 24 * 60 * 60, :second) |> DateTime.to_naive()
  end

  defp scoped(query, user) do
    case Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [x], x.server_id in ^ids)
    end
  end

  defp profile_scoped(query, user) do
    case Accounts.server_scope(user) do
      :all -> query
      ids -> where(query, [x], fragment("? && ?::integer[]", x.server_ids, ^ids))
    end
  end

  defp named(query, nil), do: query

  defp named(query, term) do
    pattern = "%" <> term <> "%"
    where(query, [x], ilike(x.player_name, ^pattern) or x.player_id == ^term)
  end

  defp profile_named(query, nil, _found), do: query

  defp profile_named(query, term, found) do
    pattern = "%" <> term <> "%"

    where(
      query,
      [x],
      ilike(x.name, ^pattern) or ilike(x.clan_tag, ^pattern) or x.player_id == ^term or
        x.player_id in ^found
    )
  end

  @doc """
  The search as the queries use it. LIKE wildcards are stripped rather than
  escaped, so a search made only of them finds nothing in particular
  instead of everybody.

      iex> HllConditionalActions.Players.Directory.search_term(" %_ ")
      nil
      iex> HllConditionalActions.Players.Directory.search_term("Rudi")
      "Rudi"
  """
  @spec search_term(String.t() | nil) :: String.t() | nil
  def search_term(query) do
    case (query || "") |> String.replace(~r/[%_\\]/, "") |> String.trim() do
      "" -> nil
      term -> term
    end
  end
end
