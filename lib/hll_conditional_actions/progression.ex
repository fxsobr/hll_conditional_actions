defmodule HllConditionalActions.Progression do
  @moduledoc """
  Achievements and seasons: what a player earns by playing, over time.

  Everything hangs off one moment, the end of a match. `record_match/3` takes
  the final `get_detailed_players` of the match and:

    1. adds each player's match to their `PlayerTotal` on that server
    2. unlocks the achievements they reached - in that match, or over their
       career - and delivers the rewards through the same executor the rules
       use (a private message, VIP with an expiry, a flag), then announces
       the unlocks of the match to everybody in one message
    3. adds the match to the score of every active season the server is
       part of - a season can run across several servers of one game

  `finalize_due_seasons/1`, run by `HllConditionalActions.Workers.
  FinalizeSeasons`, closes the seasons whose time is up: it ranks the
  players who played enough matches, gives the top ones VIP, announces them,
  and starts the next season when the season renews itself.

  A player only counts in a match they actually played: a few minutes of
  playtime is required, so somebody who joined as it ended earns nothing.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Ecto.Query

  require Logger

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Executor
  alias HllConditionalActions.Progression.Achievement
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.PlayerAchievement
  alias HllConditionalActions.Progression.PlayerTotal
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActions.Progression.Season
  alias HllConditionalActions.Progression.SeasonScore
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Action
  alias HllConditionalActions.Servers.Server

  @min_seconds_played 300

  # First key of the advisory lock taken while a season's scores change.
  @season_lock 7_140_001

  # ── Match end ──────────────────────────────────────────────────────────────

  @doc """
  Records a finished match. `players` is the `get_detailed_players` map of
  the match's last moment.

  Returns what was unlocked and how many season scores moved.
  """
  @spec record_match(Server.t(), map(), keyword()) :: %{
          unlocked: [map()],
          season_scores: integer()
        }
  def record_match(%Server{} = server, players, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:second)

    played =
      players
      |> Map.values()
      |> Enum.filter(&(is_binary(&1["player_id"]) and seconds(&1) >= @min_seconds_played))

    totals = Map.new(played, &{&1["player_id"], add_to_totals(server, &1, now)})
    unlocked = unlock_achievements(server, played, totals, now)
    announce(server, unlocked)

    outcome = Scoring.outcome(Keyword.get(opts, :gamestate))
    %{unlocked: unlocked, season_scores: add_to_seasons(server, played, outcome, now)}
  end

  defp seconds(player) do
    case player["map_playtime_seconds"] do
      value when is_integer(value) -> value
      _missing -> 0
    end
  end

  defp add_to_totals(server, player, now) do
    role = Metrics.role_match(player)

    increments = [
      matches: 1,
      kills: Metrics.match_value(player, :kills),
      deaths: Metrics.match_value(player, :deaths),
      combat: Metrics.match_value(player, :combat),
      offense: Metrics.match_value(player, :offense),
      defense: Metrics.match_value(player, :defense),
      support: Metrics.match_value(player, :support),
      vehicles_destroyed: Metrics.match_value(player, :vehicles_destroyed),
      playtime_seconds: seconds(player),
      commander_matches: if(role == :commander, do: 1, else: 0),
      leader_matches: if(role == :leader, do: 1, else: 0)
    ]

    %PlayerTotal{}
    |> Ecto.Changeset.change(
      [server_id: server.id, player_id: player["player_id"], player_name: player["name"]] ++
        increments ++ [inserted_at: now, updated_at: now]
    )
    |> Repo.insert!(
      on_conflict: [inc: increments, set: [player_name: player["name"], updated_at: now]],
      conflict_target: [:server_id, :player_id],
      returning: true
    )
  end

  # ── Achievements ───────────────────────────────────────────────────────────

  defp unlock_achievements(server, played, totals, now) do
    achievements = list_enabled_achievements(server.id)
    player_ids = Map.keys(totals)

    if achievements == [] or player_ids == [] do
      []
    else
      already = already_unlocked(player_ids)

      for player <- played,
          achievement <- achievements,
          not MapSet.member?(already, {achievement.id, player["player_id"]}),
          value = reached(achievement, player, totals[player["player_id"]]),
          value != nil,
          unlock = insert_unlock(server, achievement, player, value, now),
          unlock != nil do
        deliver(server, achievement, player)
        %{achievement: achievement, player_id: player["player_id"], player_name: player["name"]}
      end
    end
  end

  defp already_unlocked(player_ids) do
    PlayerAchievement
    |> where([u], u.player_id in ^player_ids)
    |> select([u], {u.achievement_id, u.player_id})
    |> Repo.all()
    |> MapSet.new()
  end

  # The value that met the threshold, or nil.
  defp reached(%Achievement{scope: :match} = achievement, player, _total) do
    value = Metrics.match_value(player, achievement.metric)
    if value >= achievement.threshold, do: value
  end

  defp reached(%Achievement{scope: :career} = achievement, _player, total) do
    value = Metrics.career_value(total, achievement.metric)
    if value >= achievement.threshold, do: value
  end

  defp insert_unlock(server, achievement, player, value, now) do
    %PlayerAchievement{
      achievement_id: achievement.id,
      server_id: server.id,
      player_id: player["player_id"],
      player_name: player["name"],
      value: value,
      simulated: achievement.simulation,
      unlocked_at: now
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:achievement_id, :player_id])
    |> case do
      {:ok, %{id: id} = unlock} when not is_nil(id) -> unlock
      _already -> nil
    end
  end

  # The reward, through the executor the rules use, so it behaves - and is
  # logged - exactly like a rule's actions.
  defp deliver(_server, %Achievement{simulation: true}, _player), do: :ok

  defp deliver(server, achievement, player) do
    context = Context.build(server, :match_end, player: player)
    Executor.run(reward_actions(achievement), context)
    :ok
  end

  @doc false
  @spec reward_actions(Achievement.t()) :: [Action.t()]
  def reward_actions(achievement) do
    [
      %Action{
        type: :message_player,
        parameters: %{"message" => unlock_message(achievement)}
      },
      achievement.reward_vip_hours > 0 &&
        %Action{
          type: :grant_vip,
          parameters: %{
            "description" => "Achievement: #{achievement.name}",
            "duration_hours" => achievement.reward_vip_hours
          }
        },
      present?(achievement.reward_flag) &&
        %Action{
          type: :add_player_flag,
          parameters: %{"flag" => achievement.reward_flag, "comment" => achievement.name}
        }
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  The private message a player gets when they unlock an achievement.
  Language free on purpose: the name and description are the admin's own
  words, in the server's language.
  """
  @spec unlock_message(Achievement.t()) :: String.t()
  def unlock_message(achievement) do
    [
      "#{game_mark(achievement.tier)} #{achievement.name}",
      achievement.description,
      achievement.reward_vip_hours > 0 && "+VIP #{achievement.reward_vip_hours}h"
    ]
    |> Enum.filter(&present?/1)
    |> Enum.join("\n")
  end

  @doc "The mark of a tier on the web pages (the game gets `game_mark/1`)."
  @spec tier_mark(atom()) :: String.t()
  def tier_mark(:bronze), do: "🥉"
  def tier_mark(:silver), do: "🥈"
  def tier_mark(:gold), do: "🥇"
  def tier_mark(:legendary), do: "🏆"

  @doc """
  The mark of a tier in the game, which cannot draw emoji: one star per
  tier, in plain text.

      iex> HllConditionalActions.Progression.game_mark(:gold)
      "[***]"
  """
  @spec game_mark(atom()) :: String.t()
  def game_mark(:bronze), do: "[*]"
  def game_mark(:silver), do: "[**]"
  def game_mark(:gold), do: "[***]"
  def game_mark(:legendary), do: "[****]"

  defp announce(_server, []), do: :ok

  defp announce(server, unlocked) do
    lines =
      unlocked
      |> Enum.filter(&(&1.achievement.announce and not &1.achievement.simulation))
      |> Enum.map(&"#{game_mark(&1.achievement.tier)} #{&1.player_name}: #{&1.achievement.name}")

    if lines != [] do
      Crcon.message_all_players(server, Enum.join(Enum.take(lines, 12), "\n"))
    end

    :ok
  end

  # ── Seasons ────────────────────────────────────────────────────────────────

  defp add_to_seasons(server, played, outcome, now) do
    server.id
    |> active_seasons(now)
    |> Enum.reduce(0, fn season, count -> count + add_to_season(season, played, outcome, now) end)
  end

  defp active_seasons(server_id, now) do
    Season
    |> join(:inner, [s], ss in "season_servers", on: ss.season_id == s.id)
    |> where([s, ss], ss.server_id == ^server_id and s.status == :active)
    |> where([s], s.starts_at <= ^now and s.ends_at > ^now)
    |> order_by([s], asc: s.starts_at)
    |> Repo.all()
  end

  # The whole match at once: a rating season needs every player's rating to
  # know each team's strength, so standings are read, scored together by
  # `Scoring`, and written back - under a lock on the season, since two of
  # its servers can finish a match at the same moment and a read-modify-write
  # would lose one of them.
  defp add_to_season(season, played, outcome, now) do
    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@season_lock, season.id])
        score_season(season, played, outcome, now)
      end)

    count
  end

  defp score_season(season, played, outcome, now) do
    player_ids = Enum.map(played, & &1["player_id"])

    current =
      SeasonScore
      |> where([s], s.season_id == ^season.id and s.player_id in ^player_ids)
      |> Repo.all()
      |> Map.new(fn score ->
        {score.player_id, Map.take(score, [:score, :total, :matches, :wins, :losses])}
      end)

    names = Map.new(played, &{&1["player_id"], &1["name"]})

    scored = Scoring.score_match(season, played, current, outcome)

    for {player_id, standing} <- scored do
      standing = Map.put(standing, :last_match_at, now)

      %SeasonScore{
        season_id: season.id,
        player_id: player_id,
        player_name: names[player_id],
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(standing)
      |> Repo.insert!(
        on_conflict: [
          set: Map.to_list(standing) ++ [player_name: names[player_id], updated_at: now]
        ],
        conflict_target: [:season_id, :player_id]
      )
    end

    map_size(scored)
  end

  @idle_days 14

  @doc """
  Pulls the ratings of players who stopped playing back towards the start:
  once a week, after #{@idle_days} days without a match, by the `decay` of
  each running rating season. Returns how many ratings moved.
  """
  @spec decay_ratings(DateTime.t()) :: non_neg_integer()
  def decay_ratings(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    idle_since = DateTime.add(now, -@idle_days, :day)
    week_ago = DateTime.add(now, -7, :day)

    Season
    |> where([s], s.status == :active and s.scoring == :elo)
    |> Repo.all()
    |> Enum.map(fn season -> {season, Rating.normalize(season.rating)} end)
    |> Enum.reject(fn {_season, config} -> config["decay"] == 0 end)
    |> Enum.reduce(0, fn {season, config}, count ->
      SeasonScore
      |> where([s], s.season_id == ^season.id and s.last_match_at < ^idle_since)
      |> where([s], is_nil(s.decayed_at) or s.decayed_at < ^week_ago)
      |> Repo.all()
      |> Enum.reduce(count, fn score, count ->
        score
        |> Ecto.Changeset.change(score: Rating.decayed(score.score, config), decayed_at: now)
        |> Repo.update!()

        count + 1
      end)
    end)
  end

  @doc """
  Closes every active season whose end has passed: ranks, rewards,
  announces, and renews. Returns the seasons it closed.
  """
  @spec finalize_due_seasons(DateTime.t()) :: [Season.t()]
  def finalize_due_seasons(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    Season
    |> where([s], s.status == :active and s.ends_at <= ^now)
    |> preload(:servers)
    |> Repo.all()
    |> Enum.map(&finalize_season(&1, now))
  end

  @doc """
  Closes one season now, whatever its end date.
  """
  @spec finalize_season(Season.t(), DateTime.t()) :: Season.t()
  def finalize_season(%Season{} = season, now \\ DateTime.utc_now()) do
    season = Repo.preload(season, :servers)
    now = DateTime.truncate(now, :second)

    winners =
      season |> standings() |> Enum.filter(& &1.qualified) |> Enum.take(season.winners_count)

    Enum.with_index(winners, 1)
    |> Enum.each(fn {score, rank} ->
      rewarded_at = reward_winner(season, score, rank) && now

      SeasonScore
      |> where([s], s.id == ^score.id)
      |> Repo.update_all(set: [rank: rank, rewarded_at: rewarded_at])
    end)

    announce_winners(season, winners)

    {:ok, finished} =
      season
      |> Ecto.Changeset.change(status: :finished, finished_at: now)
      |> Repo.update()

    if season.auto_renew, do: renew(season, now)

    finished
  end

  defp reward_winner(%Season{reward_vip_hours: hours}, _score, _rank) when hours <= 0, do: false

  # VIP on every server of the season: a winner of a season shared by three
  # servers is a winner on all three. Rewarded when at least one took it.
  defp reward_winner(season, score, rank) do
    expires = DateTime.add(DateTime.utc_now(), season.reward_vip_hours, :hour)

    season.servers
    |> Enum.map(fn server ->
      case Crcon.add_vip(server, score.player_id, "#{season.name} ##{rank}", expires) do
        {:ok, _result} ->
          true

        {:error, error} ->
          Logger.warning(
            "[seasons] could not reward #{score.player_id} on #{server.name} for #{season.name}: #{Exception.message(error)}"
          )

          false
      end
    end)
    |> Enum.any?()
  end

  defp announce_winners(_season, []), do: :ok

  defp announce_winners(season, winners) do
    lines =
      winners
      |> Enum.with_index(1)
      |> Enum.map(fn {score, rank} -> "#{rank}. #{score.player_name} (#{score.score})" end)

    message = Enum.join(["== #{season.name} ==" | lines], "\n")
    Enum.each(season.servers, &Crcon.message_all_players(&1, message))
    :ok
  end

  # The next season picks up where this one ended - or now, if the server
  # was down when it should have closed.
  defp renew(season, now) do
    starts_at = if DateTime.compare(season.ends_at, now) == :lt, do: now, else: season.ends_at

    create_season(%{
      name: next_name(season.name),
      server_ids: Enum.map(season.servers, & &1.id),
      scoring: season.scoring,
      rating: season.rating,
      metric: season.metric,
      weights: season.weights,
      starts_at: starts_at,
      duration_days: season.duration_days,
      winners_count: season.winners_count,
      min_matches: season.min_matches,
      reward_vip_hours: season.reward_vip_hours,
      auto_renew: true
    })
  end

  # "Season 3" becomes "Season 4"; a name without a number gets " 2".
  defp next_name(name) do
    case Regex.run(~r/^(.*?)(\d+)\s*$/, name) do
      [_all, prefix, number] -> "#{prefix}#{String.to_integer(number) + 1}"
      nil -> "#{name} 2"
    end
  end

  @doc """
  A season's standings, best first, each marked `qualified` when the player
  played enough matches to be ranked for the reward.
  """
  @spec standings(Season.t(), keyword()) :: [map()]
  def standings(%Season{} = season, opts \\ []) do
    SeasonScore
    |> where([s], s.season_id == ^season.id)
    |> order_by([s], desc: s.score, desc: s.matches, asc: s.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
    |> Enum.map(&Map.put(Map.from_struct(&1), :qualified, &1.matches >= season.min_matches))
  end

  @doc "Seasons that run on any of `server_ids`, active first, newest first."
  @spec list_seasons([term()] | :all) :: [Season.t()]
  def list_seasons(server_ids \\ :all) do
    Season
    |> then(fn query ->
      if server_ids == :all do
        query
      else
        where(
          query,
          [s],
          s.id in subquery(
            from ss in "season_servers", where: ss.server_id in ^server_ids, select: ss.season_id
          )
        )
      end
    end)
    |> order_by([s], asc: s.status, desc: s.starts_at)
    |> preload(servers: ^from(sv in Server, order_by: sv.name))
    |> Repo.all()
  end

  @spec get_season!(term()) :: Season.t()
  def get_season!(id), do: Season |> Repo.get!(id) |> Repo.preload(:servers)

  @doc """
  A changeset for the form. The servers come as `server_ids` (or one
  `server_id`) in `attrs`.
  """
  @spec change_season(Season.t(), map()) :: Ecto.Changeset.t()
  def change_season(%Season{} = season, attrs \\ %{}),
    do: Season.changeset(season, attrs, servers_of(attrs))

  @spec create_season(map()) :: {:ok, Season.t()} | {:error, Ecto.Changeset.t()}
  def create_season(attrs) do
    %Season{servers: []}
    |> Season.changeset(attrs, servers_of(attrs) || [])
    |> Repo.insert()
  end

  defp servers_of(attrs) do
    ids =
      case attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) do
        %{"server_ids" => ids} when is_list(ids) -> ids
        %{"server_id" => id} when id not in [nil, ""] -> [id]
        _none -> nil
      end

    ids &&
      ids
      |> Enum.reject(&(&1 in [nil, ""]))
      |> then(&Repo.all(from sv in Server, where: sv.id in ^&1, order_by: sv.name))
  end

  @spec delete_season(Season.t()) :: {:ok, Season.t()} | {:error, Ecto.Changeset.t()}
  def delete_season(%Season{} = season), do: Repo.delete(season)

  @doc "The server's running season, or nil."
  @spec active_season(term()) :: Season.t() | nil
  def active_season(server_id) do
    server_id |> active_seasons(DateTime.utc_now()) |> List.first()
  end

  @doc "The player's position in the server's active season, or nil."
  @spec season_rank(term(), String.t() | nil) :: {Season.t(), pos_integer(), integer()} | nil
  def season_rank(_server_id, nil), do: nil

  def season_rank(server_id, player_id) do
    with [season | _rest] <- active_seasons(server_id, DateTime.utc_now()),
         standings = standings(season, limit: 1000),
         index when is_integer(index) <- Enum.find_index(standings, &(&1.player_id == player_id)) do
      {season, index + 1, Enum.at(standings, index).score}
    else
      _none -> nil
    end
  end

  @doc "The top of the server's active season as one line, or nil."
  @spec season_line(term(), pos_integer()) :: String.t() | nil
  def season_line(server_id, count \\ 5) do
    case active_seasons(server_id, DateTime.utc_now()) do
      [season | _rest] ->
        season
        |> standings(limit: count)
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {score, rank} ->
          "#{rank}. #{score.player_name} (#{score.score})"
        end)
        |> case do
          "" -> "-"
          line -> line
        end

      [] ->
        nil
    end
  end

  # ── Achievements: CRUD and queries ─────────────────────────────────────────

  @doc "A server's achievements, with how many players unlocked each."
  @spec list_achievements(term()) :: [map()]
  def list_achievements(server_id) do
    counts =
      PlayerAchievement
      |> where([u], u.server_id == ^server_id)
      |> group_by([u], u.achievement_id)
      |> select([u], {u.achievement_id, count(u.id)})
      |> Repo.all()
      |> Map.new()

    Achievement
    |> for_server(server_id)
    |> order_by([a], asc: a.scope, asc: a.metric, asc: a.threshold)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :unlocked_count, Map.get(counts, &1.id, 0)))
  end

  defp list_enabled_achievements(server_id) do
    Achievement |> for_server(server_id) |> where([a], a.enabled) |> Repo.all()
  end

  # A server's own achievements and the older ones that belong to no server.
  defp for_server(query, server_id) do
    where(query, [a], a.server_id == ^server_id or is_nil(a.server_id))
  end

  @spec get_achievement!(term()) :: Achievement.t()
  def get_achievement!(id), do: Repo.get!(Achievement, id)

  @spec change_achievement(Achievement.t(), map()) :: Ecto.Changeset.t()
  def change_achievement(%Achievement{} = achievement, attrs \\ %{}),
    do: Achievement.changeset(achievement, attrs)

  @spec create_achievement(map()) :: {:ok, Achievement.t()} | {:error, Ecto.Changeset.t()}
  def create_achievement(attrs),
    do: %Achievement{} |> Achievement.changeset(attrs) |> Repo.insert()

  @spec update_achievement(Achievement.t(), map()) ::
          {:ok, Achievement.t()} | {:error, Ecto.Changeset.t()}
  def update_achievement(%Achievement{} = achievement, attrs),
    do: achievement |> Achievement.changeset(attrs) |> Repo.update()

  @spec delete_achievement(Achievement.t()) :: {:ok, Achievement.t()} | {:error, term()}
  def delete_achievement(%Achievement{} = achievement), do: Repo.delete(achievement)

  @doc "The latest unlocks, newest first."
  @spec recent_unlocks(term(), pos_integer()) :: [PlayerAchievement.t()]
  def recent_unlocks(server_id, count \\ 12) do
    PlayerAchievement
    |> where([u], u.server_id == ^server_id)
    |> order_by([u], desc: u.unlocked_at, desc: u.id)
    |> limit(^count)
    |> preload(:achievement)
    |> Repo.all()
  end

  @doc "A player's unlocked achievements, newest first."
  @spec player_achievements(String.t(), term()) :: [PlayerAchievement.t()]
  def player_achievements(player_id, server_id \\ nil) do
    PlayerAchievement
    |> where([u], u.player_id == ^player_id)
    |> then(fn query ->
      if server_id, do: where(query, [u], u.server_id == ^server_id), else: query
    end)
    |> order_by([u], desc: u.unlocked_at)
    |> preload(:achievement)
    |> Repo.all()
  end

  @doc "How many different players unlocked at least one achievement."
  @spec players_with_achievements(term()) :: non_neg_integer()
  def players_with_achievements(server_id) do
    PlayerAchievement
    |> where([u], u.server_id == ^server_id)
    |> select([u], count(u.player_id, :distinct))
    |> Repo.one()
  end

  @doc """
  A starter set covering fighting, teamwork and helping the server, created
  in simulation so an admin sees what they would do before they reward.

  Names and descriptions are written in the caller's locale: they become the
  admin's own data, editable afterwards.
  """
  @spec create_starter_set(term()) :: [Achievement.t()]
  def create_starter_set(server_id) do
    [
      {gettext("First blood"), gettext("20 kills in one match"), "hero-fire", :bronze, :match,
       :kills, 20, 0},
      {gettext("Sharpshooter"), gettext("40 kills in one match"), "hero-viewfinder-circle", :gold,
       :match, :kills, 40, 24},
      {gettext("Medic's pride"), gettext("1500 support in one match"), "hero-heart", :silver,
       :match, :support, 1500, 12},
      {gettext("Tank buster"), gettext("5 vehicles destroyed in one match"), "hero-truck", :gold,
       :match, :vehicles_destroyed, 5, 24},
      {gettext("Veteran"), gettext("100 matches on this server"), "hero-shield-check", :silver,
       :career, :matches, 100, 48},
      {gettext("Thousand kills"), gettext("1000 kills on this server"), "hero-bolt", :gold,
       :career, :kills, 1000, 72},
      {gettext("Voice of the team"), gettext("25 matches as commander"), "hero-megaphone", :gold,
       :career, :commander_matches, 25, 72},
      {gettext("Squad leader"), gettext("50 matches leading a squad"), "hero-user-group", :silver,
       :career, :leader_matches, 50, 48},
      {gettext("Regular"), gettext("100 hours played on this server"), "hero-clock", :legendary,
       :career, :playtime_minutes, 6000, 168}
    ]
    |> Enum.flat_map(fn {name, description, icon, tier, scope, metric, threshold, vip} ->
      case create_achievement(%{
             server_id: server_id,
             name: name,
             description: description,
             icon: icon,
             tier: tier,
             scope: scope,
             metric: metric,
             threshold: threshold,
             reward_vip_hours: vip,
             simulation: true
           }) do
        {:ok, achievement} -> [achievement]
        {:error, _changeset} -> []
      end
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
