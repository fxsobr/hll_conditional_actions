defmodule HllConditionalActions.MatchHistory do
  @moduledoc """
  The matches of several servers over a stretch of days, read from CRCON's
  match history and put together for the matches page: one list across
  servers, what is being played right now, and the numbers of the period -
  how many matches, how long they lasted, which side won, and by map.

  CRCON pages its history newest first (`get_scoreboard_maps`); a period is
  read page after page until a match older than its start shows up, so a
  month costs a few requests per server. The list carries no players; the
  size of each match comes from `details/2`, one `get_map_scoreboard` per
  match, only for the matches on screen.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Matches
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers.Server

  @page_size 100
  @max_pages 12

  @doc """
  Every match of `servers` that started in the last `days` days, newest
  first, each summary with its `:server`. `failed` lists the servers CRCON
  did not answer for.
  """
  @spec period([Server.t()], pos_integer(), DateTime.t()) :: %{
          matches: [map()],
          failed: [term()]
        }
  def period(servers, days, now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -days, :day)

    results =
      servers
      |> Task.async_stream(&{&1, server_period(&1, since)},
        timeout: 60_000,
        on_timeout: :kill_task,
        max_concurrency: 4
      )
      |> Enum.zip(servers)
      |> Enum.map(fn
        {{:ok, {server, result}}, _server} -> {server, result}
        {_timeout, server} -> {server, :error}
      end)

    %{
      matches:
        results
        |> Enum.flat_map(fn
          {server, {:ok, matches}} -> Enum.map(matches, &Map.put(&1, :server, server))
          {_server, :error} -> []
        end)
        |> Enum.sort_by(&sort_key/1, :desc),
      failed: for({server, :error} <- results, do: server.id)
    }
  end

  defp sort_key(%{started_at: %DateTime{} = at}), do: DateTime.to_unix(at)
  defp sort_key(_match), do: 0

  defp server_period(server, since, page \\ 1, acc \\ []) do
    case Matches.list(server, page: page, limit: @page_size) do
      {:ok, %{matches: matches, total: total}} ->
        {recent, older} = Enum.split_with(matches, &after?(&1, since))
        acc = acc ++ Enum.filter(recent, & &1.ended_at)

        if older != [] or matches == [] or page * @page_size >= total or page >= @max_pages,
          do: {:ok, acc},
          else: server_period(server, since, page + 1, acc)

      {:error, _reason} ->
        if acc == [], do: :error, else: {:ok, acc}
    end
  end

  defp after?(%{started_at: %DateTime{} = at}, since), do: DateTime.compare(at, since) != :lt
  defp after?(_match, _since), do: false

  @doc """
  The numbers of a list of matches: how many, the average length, the wins
  of each side, the total wins (every sector held), and the maps played
  most with the wins of each side.
  """
  @spec summary([map()]) :: map()
  def summary(matches) do
    durations = for %{duration_seconds: s} when is_integer(s) and s > 0 <- matches, do: s

    by_map =
      matches
      |> Enum.group_by(& &1.map)
      |> Enum.map(fn {map, played} ->
        %{
          map: map,
          count: length(played),
          allies: Enum.count(played, &(&1.winner == :allies)),
          axis: Enum.count(played, &(&1.winner == :axis))
        }
      end)
      |> Enum.sort_by(&{-&1.count, &1.map})

    %{
      count: length(matches),
      average_seconds: if(durations != [], do: div(Enum.sum(durations), length(durations))),
      allies: Enum.count(matches, &(&1.winner == :allies)),
      axis: Enum.count(matches, &(&1.winner == :axis)),
      total_wins: Enum.count(matches, &total_win?/1),
      by_map: by_map
    }
  end

  @doc "Whether one side ended the match holding every sector."
  @spec total_win?(map()) :: boolean()
  def total_win?(%{allied: 5, axis: 0}), do: true
  def total_win?(%{allied: 0, axis: 5}), do: true
  def total_win?(_match), do: false

  @doc """
  The players and the MVP (best teamplay) of each match, by `{server_id,
  match_id}` (match IDs are only unique on their server), read
  from CRCON a few at a time. A match CRCON cannot answer for is left out.
  """
  @spec details([map()]) :: %{
          {term(), term()} => %{players: non_neg_integer(), mvp: String.t() | nil}
        }
  def details(matches) do
    matches
    |> Task.async_stream(
      fn match ->
        case Matches.get(match.server, match.id) do
          {:ok, %{roster: roster}} -> {{match.server.id, match.id}, roster_facts(roster)}
          _error -> nil
        end
      end,
      timeout: 20_000,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, {id, facts}} -> [{id, facts}]
      _failed -> []
    end)
    |> Map.new()
  end

  defp roster_facts(roster) do
    mvp =
      case Leaderboards.top_players(roster, :teamplay, 1) do
        [best] -> best.name
        [] -> nil
      end

    %{players: map_size(roster), mvp: mvp}
  end

  @doc """
  What each server is playing now, from its game state: `%{server, map,
  mode, allied, axis, started_at}`. Servers that do not answer are left out.
  """
  @spec live([Server.t()]) :: [map()]
  def live(servers) do
    servers
    |> Task.async_stream(&{&1, Crcon.get_gamestate(&1)},
      timeout: 10_000,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, {server, {:ok, %{} = state}}} -> [live_match(server, state)]
      _failed -> []
    end)
  end

  defp live_match(server, state) do
    layer = state["current_map"] || %{}

    %{
      server: server,
      layer: layer,
      map: get_in(layer, ["map", "pretty_name"]) || layer["pretty_name"] || "?",
      mode: state["game_mode"] || layer["game_mode"],
      allied: state["allied_score"],
      axis: state["axis_score"],
      players: (state["num_allied_players"] || 0) + (state["num_axis_players"] || 0),
      started_at:
        case state["match_start"] do
          start when is_integer(start) -> DateTime.from_unix!(start)
          _unknown -> nil
        end
    }
  end

  @doc """
  The rule that posts each match to Discord on these servers - one ending
  with a match whose actions send to a webhook - with that webhook, or nil.
  """
  @spec discord_rule([term()]) :: %{rule: Rule.t(), webhook: map() | nil} | nil
  def discord_rule(server_ids) do
    Rule
    |> where([r], r.trigger_event == :match_end)
    |> where([r], r.server_id in ^server_ids or is_nil(r.server_id))
    |> order_by([r], desc: r.enabled, asc: r.id)
    |> Repo.all()
    |> Enum.find_value(fn rule ->
      case Enum.find(rule.actions, &(&1.type == :send_discord_webhook)) do
        nil -> nil
        action -> %{rule: rule, webhook: Discord.get_webhook(action.parameters["webhook_id"])}
      end
    end)
  end
end
