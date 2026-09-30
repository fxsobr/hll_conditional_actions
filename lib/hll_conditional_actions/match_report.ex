defmodule HllConditionalActions.MatchReport do
  @moduledoc """
  The report of one finished match, computed from its roster (CRCON's
  stored stats, see `HllConditionalActions.Matches`) and the rule
  executions of the app while it was played:

    * totals - kills, vehicles destroyed, team kills, players
    * the MVP (best teamplay) with their line, and the VIP a rule gave them
    * the best three of each category
    * the best squads of any type, with their leader
    * the rules that fired, grouped by rule
    * a text version for Discord
  """

  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Rules.Action

  @categories [
    :kills,
    :kill_death_ratio,
    :combat,
    :offense,
    :defense,
    :support,
    :vehicles_destroyed,
    :kills_per_minute
  ]

  @doc "The categories of the \"best by category\" panel, in order."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc """
  Everything the report shows. `executions` are the app's executions on the
  server from the match's start to a few minutes after its end, with their
  rule preloaded.
  """
  @spec build(map(), [map()]) :: map()
  def build(match, executions) do
    roster = match.roster
    players = Map.values(roster)
    mvp = mvp(roster)

    %{
      players: length(players),
      kills: sum(players, "kills"),
      vehicles: sum(players, "vehicles_destroyed"),
      team_kills: sum(players, "team_kills"),
      teams: %{
        allies: Enum.count(players, &(&1["team"] == "allies")),
        axis: Enum.count(players, &(&1["team"] == "axis"))
      },
      mvp: mvp,
      mvp_reward: mvp && mvp_reward(mvp.player_id, executions),
      best: Map.new(@categories, &{&1, Leaderboards.top_players(roster, &1, 3)}),
      squads: squads(roster),
      rules: rules(during(executions, match)),
      fired: length(during(executions, match))
    }
  end

  defp sum(players, key), do: Enum.sum_by(players, &(number(&1[key]) || 0))

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp mvp(roster) do
    case Leaderboards.top_players(roster, :teamplay, 1) do
      [%{player_id: id}] ->
        player = roster[id]
        kills = number(player["kills"]) || 0
        deaths = number(player["deaths"]) || 0

        %{
          player_id: id,
          name: player["name"],
          team: player["team"],
          role: player["role"],
          unit: player["unit_name"],
          kills: kills,
          deaths: deaths,
          kill_death_ratio: kills / max(deaths, 1),
          combat: number(player["combat"]) || 0
        }

      [] ->
        nil
    end
  end

  # A rule that gave the MVP VIP while the report's window was open.
  defp mvp_reward(player_id, executions) do
    Enum.find_value(executions, fn execution ->
      with true <- execution.player_id == player_id,
           true <- execution.status in [:executed, :partial, :simulated],
           %{} = action <- execution.rule && Enum.find(execution.rule.actions, &vip?/1) do
        %{
          rule: execution.rule,
          hours: Action.param(action, :duration_hours),
          at: execution.executed_at,
          simulated: execution.status == :simulated
        }
      else
        _other -> nil
      end
    end)
  end

  defp vip?(%{type: :grant_vip}), do: true
  defp vip?(_action), do: false

  defp during(executions, %{started_at: %DateTime{} = from, ended_at: %DateTime{} = to}) do
    to = DateTime.add(to, 300)

    Enum.filter(executions, fn execution ->
      DateTime.compare(execution.executed_at, from) != :lt and
        DateTime.compare(execution.executed_at, to) != :gt
    end)
  end

  defp during(executions, _match), do: executions

  defp squads(roster) do
    roster
    |> Leaderboards.squads()
    |> Enum.flat_map(fn {_type, squads} -> squads end)
    # The command "unit" is where CRCON puts players outside any squad.
    |> Enum.reject(&(&1.name == "command"))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(5)
    |> Enum.map(&Map.put(&1, :capacity, Leaderboards.capacity(&1.type)))
  end

  defp rules(executions) do
    executions
    |> Enum.filter(& &1.rule)
    |> Enum.group_by(& &1.rule.id)
    |> Enum.map(fn {_id, [first | _rest] = runs} ->
      %{
        rule: first.rule,
        count: length(runs),
        failed: Enum.count(runs, &(&1.status in [:failed, :partial])),
        simulated: Enum.count(runs, &(&1.status == :simulated)),
        last_at: runs |> Enum.map(& &1.executed_at) |> Enum.max(DateTime),
        player: if(length(runs) == 1, do: first.player_name)
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.rule.name})
  end

  @doc """
  The report as a Discord message: the result, the MVP, and the best of the
  main categories. Plain text, language free apart from the words passed in
  `labels` (`%{allies, axis, mvp, kills, combat, support}`).
  """
  @spec discord_text(map(), map(), String.t(), map()) :: String.t()
  def discord_text(match, report, server_name, labels) do
    best = fn category ->
      case report.best[category] do
        [top | _rest] -> "#{labels[category]}: #{top.name} (#{format(top.value)})"
        _none -> nil
      end
    end

    [
      "**#{match.map}** · #{server_name}",
      "#{labels.allies} #{match.allied || 0} × #{match.axis || 0} #{labels.axis}",
      report.mvp && "#{labels.mvp}: #{report.mvp.name}",
      best.(:kills),
      best.(:combat),
      best.(:support)
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format(value), do: to_string(value)
end
