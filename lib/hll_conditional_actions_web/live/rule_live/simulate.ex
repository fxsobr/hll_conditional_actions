defmodule HllConditionalActionsWeb.RuleLive.Simulate do
  @moduledoc """
  The event simulator: compose an event - or pick a saved real one and edit
  it - and see every enabled rule of the server that would answer it, in
  the order the engine runs them, with the actions each would take and the
  conflicts between them (`HllConditionalActions.Engine.Simulator`).

  Nothing is recorded or sent.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_rules}}

  import HllConditionalActionsWeb.DiagnosisComponents

  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Engine.Simulator
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Rules.Catalog
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.EventEditor

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    socket =
      socket
      |> assign(:page_title, gettext("Event simulator"))
      |> assign(:servers, servers)
      |> assign(:triggers, Catalog.triggers())
      |> assign(:server, List.first(servers))
      |> assign(:trigger, :player_kill)

    {:ok, reset(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("setup", params, socket) do
    server =
      Enum.find(
        socket.assigns.servers,
        socket.assigns.server,
        &(to_string(&1.id) == params["server_id"])
      )

    trigger =
      Enum.find(
        socket.assigns.triggers,
        socket.assigns.trigger,
        &(to_string(&1) == params["trigger"])
      )

    {:noreply, socket |> assign(server: server, trigger: trigger) |> reset()}
  end

  def handle_event("pick_event", %{"event_id" => id}, socket) do
    sample =
      case Enum.find(socket.assigns.events, &(to_string(&1.id) == id)) do
        nil -> blank(socket.assigns)
        saved -> saved.sample
      end

    {:noreply, socket |> assign(:sample, sample) |> simulate()}
  end

  def handle_event("edit_event", params, socket) do
    {:noreply,
     socket
     |> assign(:sample, EventEditor.apply_edits(socket.assigns.sample, params))
     |> simulate()}
  end

  defp reset(%{assigns: %{server: nil}} = socket) do
    assign(socket, events: [], sample: nil, result: nil)
  end

  defp reset(socket) do
    events =
      SavedEvents.list([socket.assigns.server.id], trigger: socket.assigns.trigger, limit: 50)

    socket
    |> assign(:events, events)
    |> assign(:sample, blank(socket.assigns))
    |> simulate()
  end

  defp blank(assigns), do: EventEditor.blank_sample(assigns.server.id, assigns.trigger)

  defp simulate(socket) do
    %{server: server, sample: sample, trigger: trigger} = socket.assigns
    context = EventEditor.to_context(%{sample | trigger: trigger}, server)
    assign(socket, :result, Simulator.simulate(Rules.list_active_rules_for(server), context))
  end

  defp conflict_text(%{kind: :double_punishment, rules: rules}) do
    gettext("%{rules} would all punish the same player for this one event.",
      rules: rule_names(rules)
    )
  end

  defp conflict_text(%{kind: :message_then_removed, rules: rules}) do
    gettext(
      "%{rules}: one messages the player while another kicks or bans them, so the message is likely never read.",
      rules: rule_names(rules)
    )
  end

  defp rule_names(rules), do: Enum.map_join(rules, ", ", &"“#{&1.name}”")

  defp conflicting_ids(conflicts) do
    conflicts |> Enum.flat_map(& &1.rules) |> MapSet.new(& &1.id)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        conflicting: conflicting_ids((assigns.result && assigns.result.conflicts) || []),
        firing:
          Enum.filter(
            (assigns.result && assigns.result.results) || [],
            &(&1.diagnosis.outcome == :fires)
          ),
        quiet:
          Enum.reject(
            (assigns.result && assigns.result.results) || [],
            &(&1.diagnosis.outcome == :fires)
          )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={
        gettext(
          "Which rules would answer an event, in order, and what they would do. Nothing is sent."
        )
      }
    >
      <.empty_state
        :if={@servers == []}
        icon="hero-server-stack"
        title={gettext("Connect a server first")}
      />

      <div :if={@server} class="grid items-start gap-4 lg:grid-cols-3">
        <.card title={gettext("The event")} icon="hero-bolt">
          <div class="space-y-3">
            <form id="simulate-setup" phx-change="setup" class="space-y-2">
              <label class="block space-y-1">
                <span class="text-xs font-medium text-subtle">{gettext("Server")}</span>
                <select name="server_id" class="pc-text-input w-full">
                  <option
                    :for={server <- @servers}
                    value={server.id}
                    selected={server.id == @server.id}
                  >
                    {server.name}
                  </option>
                </select>
              </label>
              <label class="block space-y-1">
                <span class="text-xs font-medium text-subtle">{gettext("What happens")}</span>
                <select name="trigger" class="pc-text-input w-full">
                  <option :for={trigger <- @triggers} value={trigger} selected={trigger == @trigger}>
                    {Labels.trigger(trigger)}
                  </option>
                </select>
              </label>
            </form>

            <form id="simulate-pick" phx-change="pick_event">
              <label class="block space-y-1">
                <span class="text-xs font-medium text-subtle">{gettext("Start from")}</span>
                <select name="event_id" class="pc-text-input w-full">
                  <option value="">{gettext("A made-up event")}</option>
                  <option :for={event <- @events} value={event.id}>
                    {sample_label(event.sample)}
                  </option>
                </select>
              </label>
            </form>

            <.event_fields :if={@sample} id="simulate-fields" sample={@sample} />
          </div>
        </.card>

        <div class="space-y-4 lg:col-span-2" id="simulate-results">
          <.alert
            :for={conflict <- (@result && @result.conflicts) || []}
            color="danger"
            variant="soft"
            with_icon
            label={conflict_text(conflict)}
          />

          <.card
            title={ngettext("1 rule would fire", "%{count} rules would fire", length(@firing))}
            icon="hero-bolt"
          >
            <p :if={@firing == []} class="text-sm text-subtle">
              {gettext("No enabled rule on this server would answer this event.")}
            </p>
            <ol class="space-y-3">
              <li
                :for={{entry, index} <- Enum.with_index(@firing, 1)}
                id={"sim-rule-#{entry.rule.id}"}
                class={[
                  "rounded-box border p-3",
                  if(MapSet.member?(@conflicting, entry.rule.id),
                    do: "border-error/50 bg-error/5",
                    else: "border-base-300"
                  )
                ]}
              >
                <div class="mb-2 flex items-center justify-between gap-2">
                  <.link navigate={~p"/rules/#{entry.rule}"} class="font-medium hover:underline">
                    {index}. {entry.rule.name}
                  </.link>
                  <.tone_badge :if={entry.rule.simulation} tone="info">
                    {gettext("Simulation")}
                  </.tone_badge>
                </div>
                <ul class="space-y-1">
                  <li
                    :for={action <- entry.diagnosis.actions}
                    class="rounded-box bg-base-200 px-2 py-1.5 text-xs"
                  >
                    <p class="font-medium">{Labels.action(action.type)}</p>
                    <p
                      :if={is_binary(action.detail) and action.detail != ""}
                      class="whitespace-pre-line text-subtle"
                    >
                      {action.detail}
                    </p>
                  </li>
                </ul>
              </li>
            </ol>
          </.card>

          <.card
            :if={@quiet != []}
            title={gettext("Listening, but would not fire")}
            icon="hero-minus-circle"
          >
            <ul class="divide-y divide-base-300">
              <li :for={entry <- @quiet} class="py-2">
                <details>
                  <summary class="flex cursor-pointer items-center justify-between gap-2 text-sm">
                    <span>{entry.rule.name}</span>
                    <.outcome_badge outcome={entry.diagnosis.outcome} />
                  </summary>
                  <div class="pt-2">
                    <.diagnosis diagnosis={entry.diagnosis} player={@sample.player_name} compact />
                  </div>
                </details>
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
