defmodule HllConditionalActions.Onboarding do
  @moduledoc """
  The path from a fresh install to a rule that is trusted to act on its own.

  Each step is derived from what already exists - servers, their streams,
  rules, executions, the account's two factor - rather than from a stored
  "done" flag, so a step can never claim to be finished when it is not, and
  an install set up before this existed is simply recognised as done.

  Steps have real prerequisites. A rule cannot run without a server, and a
  simulation cannot show anything before there is a rule, so those steps are
  `:locked` - shown, so the road ahead is visible, but with nothing to press
  until what they need exists. Each step's `state` is one of:

    * `:done`
    * `:current` - the one to do now, with its call to action
    * `:waiting` - nothing to do but wait (a stream connecting, a simulated
      rule that has not matched anybody yet)
    * `:blocked` - it went wrong and needs a look (a stream in error)
    * `:available` - can be done now, but it is not the next thing
    * `:locked` - needs an earlier step first (`requires` says which)

  Steps the user's role cannot do are left out.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules

  @type state :: :done | :current | :waiting | :blocked | :available | :locked
  @type step :: %{id: atom(), state: state(), requires: atom() | nil, context: map()}

  @doc """
  The steps for a user, given the servers they see and each one's stream
  status (which only the caller, holding the live subscription, knows).
  """
  @spec steps(map(), [map()], %{optional(term()) => term()}) :: [step()]
  def steps(user, servers, stream_status) do
    rules = if Accounts.can?(user, :view_rules), do: Rules.list_rules_for(user), else: []
    server = List.first(servers)
    simulating = Enum.find(rules, &(&1.enabled and &1.simulation))
    simulated? = simulated_anything?(user)

    [
      %{
        id: :server,
        permission: :manage_servers,
        done: servers != [],
        requires: nil,
        context: %{}
      },
      %{
        id: :stream,
        permission: :manage_servers,
        done: Enum.any?(servers, &(stream_status[&1.id] == :connected)),
        requires: :server,
        context: stream_context(servers, stream_status)
      },
      %{
        id: :rule,
        permission: :manage_rules,
        done: rules != [],
        requires: :server,
        context: %{server: server}
      },
      %{
        id: :simulation,
        permission: :manage_rules,
        # A rule that went straight to live has proved itself another way.
        done: simulated? or Enum.any?(rules, &(&1.enabled and not &1.simulation)),
        requires: :rule,
        context: %{rule: simulating || List.first(rules)}
      },
      %{
        id: :live,
        permission: :manage_rules,
        done: Enum.any?(rules, &(&1.enabled and not &1.simulation)),
        requires: :simulation,
        context: %{rule: simulating}
      },
      %{
        id: :two_factor,
        permission: nil,
        done: not is_nil(user.totp_confirmed_at),
        requires: nil,
        context: %{}
      }
    ]
    |> Enum.filter(&(is_nil(&1.permission) or Accounts.can?(user, &1.permission)))
    |> resolve_states()
  end

  # Decides each step's state in order: whatever is not done and has its
  # prerequisite met can be worked on, and the first of those is current -
  # unless it is one that only needs waiting for.
  defp resolve_states(steps) do
    done = for step <- steps, step.done, into: MapSet.new(), do: step.id
    visible = MapSet.new(steps, & &1.id)

    {resolved, _focus_taken} =
      Enum.map_reduce(steps, false, fn step, focus_taken ->
        state = state_of(step, unlocked?(step, done, visible), focus_taken)
        step = step |> Map.put(:state, state) |> Map.take([:id, :state, :requires, :context])

        {step, focus_taken or state in [:current, :waiting, :blocked]}
      end)

    resolved
  end

  # A prerequisite the role cannot see does not hold the step back.
  defp unlocked?(%{requires: nil}, _done, _visible), do: true

  defp unlocked?(%{requires: required}, done, visible) do
    required in done or not MapSet.member?(visible, required)
  end

  defp state_of(%{done: true}, _unlocked?, _focus_taken), do: :done
  defp state_of(_step, false, _focus_taken), do: :locked
  defp state_of(%{id: :stream, context: %{error: _}}, true, _focus_taken), do: :blocked
  defp state_of(%{id: id}, true, false) when id in [:stream, :simulation], do: :waiting
  defp state_of(_step, true, true), do: :available
  defp state_of(_step, true, false), do: :current

  # A stream in error, or none at all on an enabled server - its engine
  # stopped - is a problem to look at, not something to wait for.
  defp stream_context(servers, stream_status) do
    failing =
      Enum.find(servers, fn server ->
        server.enabled and
          (match?({:error, _reason}, stream_status[server.id]) or
             (stream_status[server.id] == :disconnected and
                HllConditionalActions.Runtime.enabled?()))
      end)

    case failing && stream_status[failing.id] do
      nil -> %{server: List.first(servers)}
      :disconnected -> %{server: failing, error: :stopped}
      {:error, reason} -> %{server: failing, error: format_reason(reason)}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)

  @doc """
  Whether the checklist is worth showing: the user can set things up and a
  step that matters is left. Two factor on its own does not keep it up; the
  account page nags about that already.
  """
  @spec show?(map(), [step()]) :: boolean()
  def show?(user, steps) do
    (Accounts.can?(user, :manage_servers) or Accounts.can?(user, :manage_rules)) and
      Enum.any?(steps, &(&1.state != :done and &1.id != :two_factor))
  end

  @doc "The step to focus on: current, waiting or blocked, or `nil`."
  @spec focus([step()]) :: step() | nil
  def focus(steps), do: Enum.find(steps, &(&1.state in [:current, :waiting, :blocked]))

  defp simulated_anything?(user) do
    user
    |> Rules.scoped_executions()
    |> where([e], e.status == :simulated)
    |> Repo.exists?()
  end
end
