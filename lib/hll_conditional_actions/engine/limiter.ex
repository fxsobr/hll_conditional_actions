defmodule HllConditionalActions.Engine.Limiter do
  @moduledoc """
  Rate limits rule executions per player.

  Two independent checks, both driven by the `rule_executions` table:

    * **cooldown** - a rule may not fire again for the same player within
      `cooldown_seconds`
    * **execution cap** - a rule may not fire more than
      `max_executions_per_player` times for the same player inside a rolling
      24 hour window

  `0` disables either check. The 24 hour window matches the TTL CRCON's own
  processor puts on its Redis counters, so rules ported from CRCON behave the
  same way.

  Rules that fire without a player (match-wide actions such as a broadcast) are
  not rate limited here; their trigger already fires once per match.
  """

  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Rule

  @execution_window_seconds 24 * 60 * 60

  @type verdict :: :ok | {:skip, :cooldown | :max_executions}

  @doc """
  Whether a rule may fire for a player right now.

      iex> alias HllConditionalActions.Engine.Limiter
      iex> alias HllConditionalActions.Rules.Rule
      iex> Limiter.check(%Rule{id: 1, cooldown_seconds: 0, max_executions_per_player: 0}, nil)
      :ok
  """
  @spec check(Rule.t(), String.t() | nil) :: verdict()
  def check(%Rule{cooldown_seconds: 0, max_executions_per_player: 0}, _player_id), do: :ok
  def check(%Rule{}, nil), do: :ok

  def check(%Rule{} = rule, player_id) do
    with :ok <- check_cooldown(rule, player_id) do
      check_execution_cap(rule, player_id)
    end
  end

  @doc """
  Seconds left before a rule may fire again for a player, or `0`.
  """
  @spec cooldown_remaining(Rule.t(), String.t() | nil) :: non_neg_integer()
  def cooldown_remaining(%Rule{cooldown_seconds: 0}, _player_id), do: 0
  def cooldown_remaining(%Rule{}, nil), do: 0

  def cooldown_remaining(%Rule{} = rule, player_id) do
    case Rules.last_executed_at(rule.id, player_id) do
      nil ->
        0

      last ->
        elapsed = DateTime.diff(DateTime.utc_now(), last, :second)
        max(rule.cooldown_seconds - elapsed, 0)
    end
  end

  defp check_cooldown(%Rule{cooldown_seconds: 0}, _player_id), do: :ok

  defp check_cooldown(%Rule{} = rule, player_id) do
    if cooldown_remaining(rule, player_id) > 0, do: {:skip, :cooldown}, else: :ok
  end

  defp check_execution_cap(%Rule{max_executions_per_player: 0}, _player_id), do: :ok

  defp check_execution_cap(%Rule{} = rule, player_id) do
    since = DateTime.add(DateTime.utc_now(), -@execution_window_seconds, :second)

    if Rules.count_executions_since(rule.id, player_id, since) >= rule.max_executions_per_player do
      {:skip, :max_executions}
    else
      :ok
    end
  end
end
