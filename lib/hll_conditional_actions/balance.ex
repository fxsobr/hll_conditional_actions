defmodule HllConditionalActions.Balance do
  @moduledoc """
  Team balance, in simulation: at the end of every match the app measures
  how far apart the two teams were and works out which groups it would move
  to close the gap, without moving anybody. The plans are kept, shown on the
  Balance page and posted to Discord, so a community can judge them before
  anything is switched for real.

  Three things feed it:

    * **a balance rating** per player (`PlayerRating`), the Elo of a rating
      season (`HllConditionalActions.Progression.Rating`, balanced preset)
      but never reset - seasons start everybody over every few weeks, and a
      balance that forgot who is strong would be useless. A player with
      few matches counts at a fraction of their distance from the start
      (`effective_rating/2`), so one lucky match does not make a newcomer
      a star
    * **partners** (`Partner`): how often two players finished a match in
      the same squad. Frequent partners are never split
    * the **matches** CRCON keeps, read into `Players.MatchStat` with each
      player's squad and the result - `learn_pending/1` learns from those
      it has not learned from yet, in the order they ended

  Why it matters, from 45 days of this community's matches: most full
  Warfare matches ended 5-0, the game swaps the factions on the next map
  but the winners stay together (90%) and win again (62%), and the side
  whose players were rated 40+ points higher won 93% of the time.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Query

  require Logger

  alias HllConditionalActions.Balance.Partner
  alias HllConditionalActions.Balance.Plan
  alias HllConditionalActions.Balance.Planner
  alias HllConditionalActions.Balance.PlayerRating
  alias HllConditionalActions.Balance.Settings
  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Players.MatchHistory
  alias HllConditionalActions.Players.MatchImport
  alias HllConditionalActions.Players.MatchStat
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  @initial 1000
  # Matches after which a rating counts in full.
  @confident_after 10
  # A partnership forgotten after this long without playing together, when
  # it only ever happened once.
  @partner_ttl_days 30

  @topic "balance"

  @doc "Subscribes to `{:balance_planned, plan}`."
  def subscribe, do: Phoenix.PubSub.subscribe(HllConditionalActions.PubSub, @topic)

  # ── Settings ───────────────────────────────────────────────────────────────

  @doc "A server's settings, or the defaults when it has none."
  @spec get_settings(term()) :: Settings.t()
  def get_settings(server_id) do
    Repo.get_by(Settings, server_id: server_id) || %Settings{server_id: server_id}
  end

  @doc "A changeset for the settings form."
  @spec change_settings(Settings.t(), map()) :: Ecto.Changeset.t()
  def change_settings(%Settings{} = settings, attrs \\ %{}),
    do: Settings.changeset(settings, attrs)

  @doc "Saves a server's settings."
  @spec save_settings(Settings.t(), map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def save_settings(%Settings{} = settings, attrs) do
    settings |> Settings.changeset(attrs) |> Repo.insert_or_update()
  end

  # ── Ratings ────────────────────────────────────────────────────────────────

  @doc """
  The rating the balance counts for a player: the stored one, pulled
  towards the start while they have few matches.

      iex> alias HllConditionalActions.Balance
      iex> Balance.effective_rating(1200, 10)
      1200.0
      iex> Balance.effective_rating(1200, 2)
      1040.0
      iex> Balance.effective_rating(nil, 0)
      1000.0
  """
  @spec effective_rating(integer() | nil, non_neg_integer()) :: float()
  def effective_rating(nil, _matches), do: @initial * 1.0

  def effective_rating(rating, matches),
    do: @initial + (rating - @initial) * min(matches, @confident_after) / @confident_after

  @doc "The stored ratings of some players of a game, by player ID."
  @spec ratings(atom() | String.t(), [String.t()]) :: %{String.t() => PlayerRating.t()}
  def ratings(_game, []), do: %{}

  def ratings(game, player_ids) do
    PlayerRating
    |> where([r], r.game == ^to_string(game) and r.player_id in ^player_ids)
    |> Repo.all()
    |> Map.new(&{&1.player_id, &1})
  end

  @doc "How many players have a balance rating, per game."
  @spec rated_players() :: %{String.t() => non_neg_integer()}
  def rated_players do
    PlayerRating
    |> group_by([r], r.game)
    |> select([r], {r.game, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "The frequent pairs among some players, as `{a, b}` with `a < b`."
  @spec partners([String.t()], pos_integer()) :: MapSet.t()
  def partners([], _min_matches), do: MapSet.new()

  def partners(player_ids, min_matches) do
    Partner
    |> where([p], p.player_a in ^player_ids and p.player_b in ^player_ids)
    |> where([p], p.matches >= ^min_matches)
    |> select([p], {p.player_a, p.player_b})
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Learning ───────────────────────────────────────────────────────────────

  @doc """
  Learns from the matches of a server read into the history and not learned
  from yet, oldest first: ratings move and partners are counted. Matches
  without a result (read before results were kept) are marked and skipped.
  Returns how many matches were learned from.
  """
  @spec learn_pending(Server.t()) :: non_neg_integer()
  def learn_pending(%Server{} = server) do
    MatchImport
    |> where([i], i.server_id == ^server.id and is_nil(i.balance_learned_at))
    |> order_by([i], asc: i.ended_at, asc: i.id)
    |> limit(200)
    |> Repo.all()
    |> Enum.count(&learn(server, &1))
  end

  # One match that cannot be learned from is logged and left behind, marked,
  # so it neither stops the others nor comes back every five minutes.
  defp learn(server, %MatchImport{} = import) do
    do_learn(server, import)
  rescue
    error ->
      Logger.error(
        "[balance] #{server.name}: match #{import.match_id} skipped: #{Exception.message(error)}"
      )

      import
      |> Ecto.Changeset.change(balance_learned_at: DateTime.utc_now(:second))
      |> Repo.update()

      false
  end

  defp do_learn(server, %MatchImport{} = import) do
    rows =
      MatchStat
      |> where([s], s.server_id == ^server.id and s.match_id == ^import.match_id)
      |> Repo.all()

    learned? =
      import.allied_score != nil and rows != [] and
        Enum.any?(rows, &(&1.unit_name != nil))

    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      if learned? do
        update_ratings(server.game, rows, import, now)
        count_partners(rows, import.ended_at || now)
      end

      import
      |> Ecto.Changeset.change(balance_learned_at: now)
      |> Repo.update!()
    end)

    learned?
  end

  defp update_ratings(game, rows, import, now) do
    game = to_string(game)
    stored = ratings(game, Enum.map(rows, & &1.player_id))

    current =
      Map.new(stored, fn {id, r} ->
        {id, %{score: r.rating, total: 0, matches: r.matches, wins: 0, losses: 0}}
      end)

    outcome =
      Scoring.outcome(%{"allied_score" => import.allied_score, "axis_score" => import.axis_score})

    players = Enum.map(rows, &roster_line/1)
    config = Rating.preset("balanced")
    names = Map.new(rows, &{&1.player_id, &1.player_name})

    entries =
      for {id, standing} <- Rating.score_match(config, players, current, outcome) do
        %{
          game: game,
          player_id: id,
          player_name: names[id],
          rating: standing.score,
          matches: standing.matches,
          last_match_at: import.ended_at || now,
          inserted_at: now,
          updated_at: now
        }
      end

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(
      &Repo.insert_all(PlayerRating, &1,
        on_conflict: {:replace, [:rating, :matches, :player_name, :last_match_at, :updated_at]},
        conflict_target: [:game, :player_id]
      )
    )
  end

  defp roster_line(%MatchStat{} = row) do
    %{
      "player_id" => row.player_id,
      "team" => row.team,
      "kills" => row.kills,
      "deaths" => row.deaths,
      "team_kills" => row.team_kills,
      "combat" => row.combat,
      "offense" => row.offense,
      "defense" => row.defense,
      "support" => row.support,
      "map_playtime_seconds" => row.playtime_seconds
    }
  end

  # Ten minutes in the same squad, at the end of the match, makes a pair.
  @partner_min_seconds 600

  defp count_partners(rows, at) do
    pairs =
      rows
      |> Enum.filter(
        &(not is_nil(&1.unit_name) and &1.team in ["allies", "axis"] and
            &1.playtime_seconds >= @partner_min_seconds)
      )
      |> Enum.group_by(&{&1.team, &1.unit_name})
      |> Enum.flat_map(fn {_squad, members} ->
        ids = members |> Enum.map(& &1.player_id) |> Enum.uniq() |> Enum.sort()
        for {a, i} <- Enum.with_index(ids), b <- Enum.drop(ids, i + 1), do: {a, b}
      end)

    pairs
    |> Enum.map(fn {a, b} -> %{player_a: a, player_b: b, matches: 1, last_at: at} end)
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(Partner, &1,
        on_conflict:
          from(p in Partner,
            update: [inc: [matches: 1], set: [last_at: fragment("EXCLUDED.last_at")]]
          ),
        conflict_target: [:player_a, :player_b]
      )
    )
  end

  @doc "Forgets partnerships that happened once, long ago. Returns how many."
  @spec prune_partners(DateTime.t()) :: non_neg_integer()
  def prune_partners(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@partner_ttl_days, :day)

    {count, _} =
      Partner
      |> where([p], p.matches < 2 and p.last_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  @doc """
  Reads up to `count` of a server's latest matches from CRCON - including
  the ones read before squads and results were kept - and learns from all
  of them again, from scratch, in order. For a first install, or after
  changing how ratings work. Ratings are shared by every server of the
  game, so every server's matches are learned again.
  """
  @spec rebuild([Server.t()], pos_integer()) :: %{
          imported: non_neg_integer(),
          learned: non_neg_integer()
        }
  def rebuild(servers, count \\ 500) do
    imported = Enum.sum_by(servers, &import_history(&1, count))

    Repo.delete_all(PlayerRating)
    Repo.delete_all(Partner)

    server_ids = Enum.map(servers, & &1.id)

    MatchImport
    |> where([i], i.server_id in ^server_ids)
    |> Repo.update_all(set: [balance_learned_at: nil])

    by_id = Map.new(servers, &{&1.id, &1})

    learned =
      MatchImport
      |> where([i], i.server_id in ^server_ids)
      |> order_by([i], asc: i.ended_at, asc: i.id)
      |> Repo.all()
      |> Enum.count(&learn(by_id[&1.server_id], &1))

    %{imported: imported, learned: learned}
  end

  defp import_history(server, count) do
    complete =
      MatchImport
      |> where([i], i.server_id == ^server.id and not is_nil(i.allied_score))
      |> select([i], i.match_id)
      |> Repo.all()
      |> MapSet.new()

    case Crcon.get_scoreboard_maps(server, page: 1, limit: count) do
      {:ok, %{"maps" => maps}} when is_list(maps) ->
        maps
        |> Enum.filter(&((is_map(&1) and &1["id"]) && &1["end"]))
        |> Enum.reject(&MapSet.member?(complete, to_string(&1["id"])))
        |> Task.async_stream(&MatchHistory.import_match(server, &1["id"]),
          max_concurrency: 2,
          timeout: :timer.seconds(30),
          on_timeout: :kill_task
        )
        |> Enum.count(&match?({:ok, :ok}, &1))

      _error ->
        0
    end
  end

  # ── Planning ───────────────────────────────────────────────────────────────

  # CRCON can write MATCH START or MATCH ENDED twice; a second one within
  # this window is the same match.
  @same_match_minutes 10
  # The previous match ended at most this long before the warmup.
  @previous_window_minutes 20
  # A warmup decision whose match never reported its end is left open no
  # longer than this.
  @open_hours 3
  # Fewer of the previous winners than this in the warmup is not a group.
  @min_stack 10

  @doc """
  The decision, taken in the two minutes of preparation of a match - the
  only time the balance may act. Reads the teams CRCON reports now (or,
  while it reports none, the previous match's sides swapped), finds the
  previous match's dominant group together again, applies the server's rule
  and, when it fires, works out the groups to move. Nobody is moved: the
  decision is kept and posted. Returns it, or nil when there was nothing to
  decide.
  """
  @spec decide_warmup(Server.t(), map(), map() | nil, keyword()) :: Plan.t() | nil
  def decide_warmup(%Server{} = server, players, gamestate, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    settings = get_settings(server.id)
    previous = previous_match(server.id, now)
    {roster, source} = warmup_roster(players, previous)

    cond do
      length(roster) < 2 -> nil
      recent_decision?(server.id, now) -> nil
      true -> insert_decision(server, settings, roster, source, previous, gamestate, now)
    end
  end

  defp insert_decision(server, settings, roster, source, previous, gamestate, now) do
    players = rated(server.game, roster)
    stack = stack(previous, players, settings)
    gap = Planner.gap(Planner.units(players, MapSet.new()))
    fired = fired(settings.rule, abs(gap) >= settings.trigger_gap, stack != nil)
    strong = if gap >= 0, do: :allies, else: :axis

    plan =
      %Plan{
        server_id: server.id,
        map: map_name(gamestate || %{}),
        started_at: now,
        source: source,
        previous_id: previous && previous.id,
        players: length(players),
        allies_rating: rounded(side_average(players, :allies)),
        axis_rating: rounded(side_average(players, :axis)),
        gap: round(abs(gap)),
        gap_after: round(abs(gap)),
        strong_team: to_string(strong),
        strong_ids: for(p <- players, p.team == strong, do: p.id),
        stack_ids: if(stack, do: MapSet.to_list(stack.ids), else: []),
        stack_side: stack && to_string(stack.side),
        stack_together: stack && stack.together,
        roster: Enum.map(players, &roster_entry/1),
        teams: team_totals(players),
        status: "balanced"
      }
      |> with_decision(fired, server, settings, players, stack, now)
      |> Repo.insert!()

    announce(server, settings, plan)
    Phoenix.PubSub.broadcast(HllConditionalActions.PubSub, @topic, {:balance_planned, plan})
    plan
  end

  defp with_decision(plan, nil, _server, _settings, _players, _stack, _now), do: plan

  defp with_decision(plan, fired, _server, settings, players, stack, now) do
    resting = resting_players(settings.cooldown_hours, now)

    planned =
      Enum.map(players, fn p ->
        boost = if stack && MapSet.member?(stack.ids, p.id), do: settings.stack_bonus, else: 0

        %{
          p
          | rating: p.rating + boost,
            movable?: p.movable? and not MapSet.member?(resting, p.id)
        }
      end)

    result =
      Planner.plan(planned, partners(Enum.map(players, & &1.id), settings.partner_matches),
        target_gap: max(div(settings.trigger_gap, 2), 5),
        max_moves: settings.max_moves,
        max_count_gap: settings.max_count_gap
      )

    moved = result.moves |> Enum.flat_map(& &1.players) |> MapSet.new(& &1.id)

    after_players =
      Enum.map(players, fn p ->
        if MapSet.member?(moved, p.id), do: %{p | team: other(p.team)}, else: p
      end)

    %{
      plan
      | status: "simulated",
        rule_fired: fired,
        gap_after: round(abs(Planner.gap(Planner.units(after_players, MapSet.new())))),
        moves: Enum.map(result.moves, &move_entry(&1, players))
    }
  end

  # Which test made the decision, or nil when the rule did not fire.
  defp fired("gap", gap?, _previous?), do: if(gap?, do: "gap")
  defp fired("previous", _gap?, previous?), do: if(previous?, do: "previous")
  defp fired("both", gap?, previous?), do: if(gap? and previous?, do: "both")

  defp fired(_either, gap?, previous?) do
    cond do
      gap? and previous? -> "both"
      gap? -> "gap"
      previous? -> "previous"
      true -> nil
    end
  end

  # The teams of the warmup; while CRCON reports none - the preparation can
  # come before it does - the sides the players of the previous match ended
  # on, swapped, since the game swaps the factions on a new map.
  defp warmup_roster(players, previous) do
    roster = roster(players)

    present =
      for {_id, p} <- players || %{}, is_map(p), is_binary(p["player_id"]), do: p["player_id"]

    if length(roster) * 2 >= max(length(present), 2) or is_nil(previous) do
      {roster, "warmup"}
    else
      here = MapSet.new(present)
      by_id = Map.new(players || %{}, fn {_id, p} -> {p["player_id"], p} end)

      swapped =
        for entry <- previous_roster(previous),
            MapSet.member?(here, entry["id"]),
            team = team(entry["team"]),
            do: %{
              id: entry["id"],
              name: entry["name"],
              team: other(team),
              squad: squad(entry["squad"]),
              movable?: not commander?(by_id[entry["id"]] || %{}),
              role: entry["role"],
              level: entry["level"],
              kills: 0,
              points: 0
            }

      {swapped, "previous"}
    end
  end

  defp previous_roster(%Plan{end_roster: [_ | _] = roster}), do: roster
  defp previous_roster(%Plan{roster: roster}), do: roster || []

  # The match that ended just before this warmup, if it was seen.
  defp previous_match(server_id, now) do
    since = DateTime.add(now, -@previous_window_minutes, :minute)

    Plan
    |> where([p], p.server_id == ^server_id and p.ended_at > ^since and p.ended_at <= ^now)
    |> order_by(desc: :ended_at)
    |> limit(1)
    |> Repo.one()
  end

  # The previous match's winners, when they were dominant and stand together
  # on one side again.
  defp stack(nil, _players, _settings), do: nil

  defp stack(%Plan{} = previous, players, settings) do
    with true <- dominant?(previous, settings),
         [_ | _] = winners <- previous.winner_ids do
      winners = MapSet.new(winners)
      here = Enum.filter(players, &MapSet.member?(winners, &1.id))

      {side, count} =
        here |> Enum.frequencies_by(& &1.team) |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)

      if length(here) >= @min_stack and count * 100 >= settings.together * length(here) do
        %{
          side: side,
          together: round(count * 100 / length(here)),
          ids: MapSet.new(for p <- here, p.team == side, do: p.id)
        }
      end
    else
      _not_dominant -> nil
    end
  end

  defp dominant?(%Plan{kills_ratio: kills, points_ratio: points}, settings) do
    (is_integer(kills) and kills >= settings.kills_ratio) or
      (is_integer(points) and points >= settings.points_ratio)
  end

  # Players a decision moved within the cooldown, on any server.
  defp resting_players(0, _now), do: MapSet.new()

  defp resting_players(hours, now) do
    since = DateTime.add(now, -hours, :hour)

    Plan
    |> where([p], p.status == "simulated" and p.started_at > ^since)
    |> select([p], p.moves)
    |> Repo.all()
    |> Enum.flat_map(fn moves -> Enum.flat_map(moves, &Map.get(&1, "players", [])) end)
    |> MapSet.new(& &1["id"])
  end

  defp recent_decision?(server_id, now) do
    since = DateTime.add(now, -@same_match_minutes, :minute)
    Repo.exists?(from p in Plan, where: p.server_id == ^server_id and p.started_at > ^since)
  end

  @doc """
  The end of a match: its result, the roster as it finished, the winners
  and how much they out-did the loser - what the next warmup reads. Completes
  the match's warmup decision, or keeps the end alone (`"measured"`) when
  the warmup was missed. Returns the row, or nil when there was nothing to
  keep.
  """
  @spec close_match(Server.t(), map(), map() | nil, keyword()) :: Plan.t() | nil
  def close_match(%Server{} = server, players, gamestate, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    gamestate = gamestate || %{}
    roster = roster(players)

    cond do
      length(roster) < 2 -> nil
      recent_end?(server.id, now) -> nil
      true -> record_end(server, rated(server.game, roster), gamestate, now)
    end
  end

  defp record_end(server, players, gamestate, now) do
    winner = Scoring.winner(gamestate)
    winner = if winner in [:allies, :axis], do: winner
    end_fields = end_fields(players, gamestate, winner, now)

    plan =
      case open_decision(server.id, now) do
        %Plan{} = open ->
          open
          |> Ecto.Changeset.change(
            Map.merge(end_fields, %{
              map: open.map || end_fields.map,
              strong_won_again: stack_won(open, winner)
            })
          )
          |> Repo.update!()

        nil ->
          gap = Planner.gap(Planner.units(players, MapSet.new()))

          %Plan{
            server_id: server.id,
            status: "measured",
            players: length(players),
            allies_rating: rounded(side_average(players, :allies)),
            axis_rating: rounded(side_average(players, :axis)),
            gap: round(abs(gap)),
            gap_after: round(abs(gap)),
            strong_team: if(gap >= 0, do: "allies", else: "axis"),
            roster: Enum.map(players, &roster_entry/1)
          }
          |> struct(end_fields)
          |> Repo.insert!()
      end

    Phoenix.PubSub.broadcast(HllConditionalActions.PubSub, @topic, {:balance_planned, plan})
    plan
  end

  defp end_fields(players, gamestate, winner, now) do
    ratio = fn key ->
      if winner do
        won =
          players |> Enum.filter(&(&1.team == winner)) |> Enum.sum_by(&(Map.get(&1, key) || 0))

        lost =
          players
          |> Enum.filter(&(&1.team == other(winner)))
          |> Enum.sum_by(&(Map.get(&1, key) || 0))

        round(won * 100 / max(lost, 1))
      end
    end

    %{
      map: map_name(gamestate),
      ended_at: now,
      allied_score: gamestate["allied_score"],
      axis_score: gamestate["axis_score"],
      end_roster: Enum.map(players, &roster_entry/1),
      teams: team_totals(players),
      winner_ids: if(winner, do: for(p <- players, p.team == winner, do: p.id), else: []),
      kills_ratio: ratio.(:kills),
      points_ratio: ratio.(:points)
    }
  end

  defp stack_won(%Plan{stack_side: side}, winner) when is_binary(side) and not is_nil(winner),
    do: side == to_string(winner)

  defp stack_won(_plan, _winner), do: nil

  defp open_decision(server_id, now) do
    since = DateTime.add(now, -@open_hours, :hour)

    Plan
    |> where([p], p.server_id == ^server_id and p.started_at > ^since and is_nil(p.ended_at))
    |> order_by(desc: :started_at)
    |> limit(1)
    |> Repo.one()
  end

  defp recent_end?(server_id, now) do
    since = DateTime.add(now, -@same_match_minutes, :minute)
    Repo.exists?(from p in Plan, where: p.server_id == ^server_id and p.ended_at > ^since)
  end

  defp roster(players) do
    for {_id, player} <- players || %{},
        is_map(player),
        is_binary(player["player_id"]),
        team = team(player["team"]),
        do: %{
          id: player["player_id"],
          name: player["name"],
          team: team,
          squad: squad(player["unit_name"]),
          movable?: not commander?(player),
          role: player["role"],
          level: player["level"],
          kills: int(player["kills"]),
          points:
            int(player["combat"]) + int(player["offense"]) + int(player["defense"]) +
              int(player["support"])
        }
  end

  defp int(value) when is_integer(value), do: value
  defp int(_other), do: 0

  defp side_average(players, team) do
    ratings = for p <- players, p.team == team, do: p.rating
    if ratings != [], do: Enum.sum(ratings) / length(ratings)
  end

  defp rounded(nil), do: nil
  defp rounded(value), do: round(value)

  defp roster_entry(player) do
    %{
      "id" => player.id,
      "name" => player[:name],
      "team" => to_string(player.team),
      "squad" => player[:squad],
      "rating" => round(player.rating),
      "matches" => player[:matches] || 0,
      "role" => player[:role],
      "level" => player[:level],
      "kills" => player[:kills] || 0,
      "points" => player[:points] || 0,
      "movable" => Map.get(player, :movable?, true)
    }
  end

  defp team_totals(players) do
    Map.new([:allies, :axis], fn team ->
      members = Enum.filter(players, &(&1.team == team))

      {to_string(team),
       %{
         "players" => length(members),
         "rating" => rounded(side_average(players, team)),
         "kills" => Enum.sum_by(members, &(&1[:kills] || 0)),
         "points" => Enum.sum_by(members, &(&1[:points] || 0))
       }}
    end)
  end

  # Each player with the rating the balance counts for them.
  defp rated(game, roster) do
    stored = ratings(game, Enum.map(roster, & &1.id))

    Enum.map(roster, fn player ->
      r = stored[player.id]
      matches = (r && r.matches) || 0

      player
      |> Map.put(:rating, effective_rating(r && r.rating, matches))
      |> Map.put(:matches, matches)
    end)
  end

  # The team a unit leaves is where it stood before the plan flipped it;
  # ratings are the players' own, without the group's extra points.
  defp move_entry(unit, players) do
    own = Map.new(players, &{&1.id, &1.rating})

    %{
      "from" => to_string(other(unit.team)),
      "squad" => unit.squad,
      "players" =>
        Enum.map(unit.players, fn p ->
          %{"id" => p.id, "name" => p[:name], "rating" => round(own[p.id] || p.rating)}
        end)
    }
  end

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc "The latest plans of some servers, newest first."
  @spec list_plans([term()], keyword()) :: [Plan.t()]
  def list_plans(server_ids, opts \\ []) do
    Plan
    |> where([p], p.server_id in ^server_ids)
    |> filter_status(Keyword.get(opts, :status))
    |> order_by([p], desc: coalesce(p.started_at, p.ended_at), desc: p.id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload(:server)
    |> Repo.all()
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [p], p.status == ^status)

  @doc """
  What the plans of some servers say over the last `days`: matches seen,
  how many were unbalanced, the average gap before and after, and how often
  the stronger team won again on the next map.
  """
  @spec summary([term()], pos_integer()) :: map()
  def summary(server_ids, days \\ 7) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    row =
      Plan
      |> where([p], p.server_id in ^server_ids)
      |> where([p], coalesce(p.started_at, p.ended_at) > ^since)
      |> select([p], %{
        matches: count(p.id),
        unbalanced: filter(count(p.id), p.status == "simulated"),
        gap: avg(p.gap),
        gap_after: avg(p.gap_after),
        repeat_known: filter(count(p.id), not is_nil(p.strong_won_again)),
        repeated: filter(count(p.id), p.strong_won_again == true)
      })
      |> Repo.one()

    %{
      matches: row.matches,
      unbalanced: row.unbalanced,
      gap: row.gap && round(Decimal.to_float(row.gap)),
      gap_after: row.gap_after && round(Decimal.to_float(row.gap_after)),
      repeat_rate: if(row.repeat_known > 0, do: round(row.repeated * 100 / row.repeat_known))
    }
  end

  @doc """
  The two teams of a live roster with their average balance ratings, for
  the page's "right now".
  """
  @spec strength(Server.t(), map()) :: %{allies: map(), axis: map(), gap: integer()}
  def strength(%Server{} = server, players) do
    rated = rated(server.game, roster(players))

    side = fn team ->
      ratings = for p <- rated, p.team == team, do: p.rating

      %{
        players: length(ratings),
        rating: if(ratings != [], do: round(Enum.sum(ratings) / length(ratings)))
      }
    end

    allies = side.(:allies)
    axis = side.(:axis)
    %{allies: allies, axis: axis, gap: abs((allies.rating || 0) - (axis.rating || 0))}
  end

  # ── Discord ────────────────────────────────────────────────────────────────

  defp announce(_server, %Settings{webhook_id: nil}, _plan), do: :ok
  defp announce(_server, _settings, %Plan{status: "balanced"}), do: :ok

  defp announce(server, settings, plan) do
    HllConditionalActions.Workers.DeliverWebhook.enqueue(settings.webhook_id, %{
      "content" => discord_text(server, plan),
      "allowed_mentions" => %{"parse" => []}
    })
  end

  @doc false
  def discord_text(server, plan) do
    Gettext.with_locale(
      HllConditionalActionsWeb.Gettext,
      Application.get_env(:hll_conditional_actions, :default_locale, "en"),
      fn ->
        groups =
          Enum.map_join(plan.moves, "\n", fn move ->
            names = Enum.map_join(move["players"], ", ", &(&1["name"] || &1["id"]))

            "• " <>
              gettext("%{squad} (%{count}) from %{team}: %{names}",
                squad: move["squad"] || gettext("no squad"),
                count: length(move["players"]),
                team: team_label(move["from"]),
                names: names
              )
          end)

        gettext(
          "⚖️ **%{server}** · %{map}: %{strong} stronger by %{gap} points. Simulation: moving %{count} players to the other team would leave %{after} points.",
          server: server.name,
          map: plan.map || "?",
          strong: team_label(plan.strong_team),
          gap: plan.gap,
          count: Plan.moved(plan),
          after: plan.gap_after
        ) <> if(groups != "", do: "\n" <> groups, else: "")
      end
    )
  end

  defp team_label("allies"), do: gettext("Allies")
  defp team_label(_axis), do: gettext("Axis")

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp team(team) do
    case team |> to_string() |> String.downcase() do
      "allies" -> :allies
      "axis" -> :axis
      _other -> nil
    end
  end

  defp other(:allies), do: :axis
  defp other(:axis), do: :allies

  defp squad(nil), do: nil
  defp squad(""), do: nil
  defp squad(name) when is_binary(name), do: String.downcase(name)
  defp squad(_other), do: nil

  defp commander?(player) do
    role = player["role"] |> to_string() |> String.downcase()
    role in ["armycommander", "commander"] or squad(player["unit_name"]) == "command"
  end

  defp map_name(%{"current_map" => %{} = map}),
    do: get_in(map, ["map", "pretty_name"]) || map["pretty_name"] || map["id"]

  defp map_name(_gamestate), do: nil
end
