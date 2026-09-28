defmodule HllConditionalActionsWeb.RuleLive.WhyNot do
  @moduledoc """
  "Why didn't it fire?" on the rule page.

  Pick a player, optionally a time window, and every saved event of the
  rule's trigger for that player is walked through the engine's checks
  (`HllConditionalActions.Engine.Diagnosis`): the step the rule stopped at -
  disabled, paused, exempt, cooldown, cap, or the condition that failed with
  the value read against the value expected. Limits are replayed as they
  stood when the event arrived. When the rule did fire, the execution is
  linked instead.
  """

  use HllConditionalActionsWeb, :live_component

  import HllConditionalActionsWeb.DiagnosisComponents

  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActionsWeb.EventEditor

  @limit 25

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    servers =
      Enum.filter(assigns.servers, fn server ->
        server.game == assigns.rule.game and
          (is_nil(assigns.rule.server_id) or server.id == assigns.rule.server_id)
      end)

    {:ok,
     socket
     |> assign(id: assigns.id, rule: assigns.rule, servers: servers)
     |> assign_new(:query, fn -> %{"player" => "", "from" => "", "to" => ""} end)
     |> assign_new(:results, fn -> nil end)
     |> assign_new(:players, fn -> SavedEvents.players(Enum.map(servers, & &1.id)) end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("search", %{"why" => query}, socket) do
    player = String.trim(query["player"] || "")

    results =
      if player == "" do
        nil
      else
        socket.assigns.servers
        |> Enum.map(& &1.id)
        |> SavedEvents.list(
          trigger: socket.assigns.rule.trigger_event,
          player: player,
          from: parse_time(query["from"]),
          to: parse_time(query["to"]),
          limit: @limit
        )
        |> Enum.flat_map(&explain(&1, socket.assigns))
      end

    {:noreply, assign(socket, query: query, results: results)}
  end

  defp explain(saved, %{rule: rule, servers: servers}) do
    case Enum.find(servers, &(&1.id == saved.server_id)) do
      nil ->
        []

      server ->
        sample = saved.sample
        context = EventEditor.to_context(sample, server)

        [
          %{
            saved: saved,
            server: server,
            diagnosis: Diagnosis.diagnose(rule, context, at: saved.occurred_at),
            execution: Diagnosis.execution_for(rule, sample.player_id, saved.occurred_at)
          }
        ]
    end
  end

  # `datetime-local` posts "2026-09-26T21:30", read as UTC like the rest
  # of the stored times.
  defp parse_time(value) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _error -> nil
    end
  end

  defp parse_time(_value), do: nil

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-4">
      <.card
        title={gettext("Why didn't it fire?")}
        icon="hero-question-mark-circle"
        subtitle={
          gettext(
            "Pick a player to see, for each of their recent \"%{trigger}\" events, where this rule stopped.",
            trigger: Labels.trigger(@rule.trigger_event)
          )
        }
      >
        <form
          id="why-not-form"
          phx-submit="search"
          phx-target={@myself}
          class="grid gap-3 sm:grid-cols-4"
        >
          <label class="space-y-1 sm:col-span-2">
            <span class="text-xs font-medium text-subtle">{gettext("Player (name or ID)")}</span>
            <input
              type="text"
              name="why[player]"
              value={@query["player"]}
              list="why-not-players"
              autocomplete="off"
              class="pc-text-input w-full"
            />
            <datalist id="why-not-players">
              <option :for={{player_id, name} <- @players} value={player_id}>{name}</option>
            </datalist>
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-subtle">{gettext("From (UTC)")}</span>
            <input
              type="datetime-local"
              name="why[from]"
              value={@query["from"]}
              class="pc-text-input w-full"
            />
          </label>
          <label class="space-y-1">
            <span class="text-xs font-medium text-subtle">{gettext("To (UTC)")}</span>
            <input
              type="datetime-local"
              name="why[to]"
              value={@query["to"]}
              class="pc-text-input w-full"
            />
          </label>
          <div class="sm:col-span-4">
            <.button type="submit" size="sm" icon="hero-magnifying-glass" label={gettext("Explain")} />
          </div>
        </form>
      </.card>

      <.empty_state
        :if={@results == []}
        icon="hero-inbox"
        title={gettext("No saved event for that player")}
        description={
          gettext(
            "Only the latest events of each trigger are kept, per server. Try a wider window, or check the player's ID."
          )
        }
      />

      <ul :if={@results not in [nil, []]} id="why-not-results" class="space-y-3">
        <li :for={result <- @results} id={"why-#{result.saved.id}"}>
          <.card>
            <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
              <div class="min-w-0">
                <p class="font-medium">
                  {result.saved.sample.player_name || gettext("Unknown player")}
                </p>
                <p class="text-xs text-muted">
                  <.local_time
                    id={"why-at-#{result.saved.id}"}
                    at={result.saved.occurred_at}
                    format="datetime"
                  /> · {result.server.name}
                </p>
              </div>
              <.tone_badge :if={result.execution} tone="success" icon="hero-bolt">
                {gettext("Fired")}
              </.tone_badge>
              <.outcome_badge :if={!result.execution} outcome={result.diagnosis.outcome} />
            </div>

            <p :if={result.execution} class="text-sm">
              {gettext("The rule fired for this event.")}
              <.link
                navigate={
                  ~p"/executions?#{[rule_id: @rule.id, player: result.execution.player_name]}"
                }
                class="font-medium text-primary hover:underline"
              >
                {gettext("Open the execution")}
              </.link>
            </p>

            <.diagnosis
              :if={!result.execution}
              diagnosis={result.diagnosis}
              player={result.saved.sample.player_name}
              compact
            />
          </.card>
        </li>
      </ul>
    </div>
    """
  end
end
