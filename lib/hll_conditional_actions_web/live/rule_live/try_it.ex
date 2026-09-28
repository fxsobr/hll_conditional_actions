defmodule HllConditionalActionsWeb.RuleLive.TryIt do
  @moduledoc """
  The builder's "try it" panel.

  Evaluates the rule *as typed* - unsaved edits included - against either a
  saved real event (`HllConditionalActions.Engine.SavedEvents`, so it works
  with no server online) or a player connected right now. The event's fields
  can be edited to ask "and what if he had used a knife?". The verdict shows
  every check the engine makes, each condition's actual against expected
  value, and the actions that would run with their messages rendered.
  Nothing is ever sent to the game from here.

  The parent passes `rule` on every edit; the panel re-judges its current
  event each time, so the verdict follows the typing.
  """

  use HllConditionalActionsWeb, :live_component

  import HllConditionalActionsWeb.DiagnosisComponents

  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Engine.Snapshot
  alias HllConditionalActionsWeb.EventEditor

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       mode: "saved",
       events: [],
       events_key: nil,
       sample: nil,
       from_saved?: false,
       live_server_id: nil,
       players: [],
       snapshot: nil,
       loading?: false,
       error: nil,
       diagnosis: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id, :rule, :servers, :game]))
    scope = scope_servers(socket.assigns.servers, socket.assigns.rule)
    key = {socket.assigns.rule.trigger_event, Enum.map(scope, & &1.id)}

    socket =
      if socket.assigns.events_key == key do
        socket
      else
        events =
          SavedEvents.list(Enum.map(scope, & &1.id),
            trigger: socket.assigns.rule.trigger_event,
            limit: 50
          )

        socket
        |> assign(events: events, events_key: key)
        |> drop_stale_sample()
      end

    {:ok, judge(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("mode", %{"mode" => mode}, socket) when mode in ["saved", "live"] do
    {:noreply, assign(socket, mode: mode, sample: nil, diagnosis: nil, error: nil)}
  end

  def handle_event("pick_event", %{"event_id" => id}, socket) do
    case Enum.find(socket.assigns.events, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, assign(socket, sample: nil, diagnosis: nil)}

      saved ->
        {:noreply, socket |> assign(sample: saved.sample, from_saved?: true) |> judge()}
    end
  end

  def handle_event("edit_event", params, socket) do
    case socket.assigns.sample do
      nil ->
        {:noreply, socket}

      sample ->
        {:noreply, socket |> assign(:sample, EventEditor.apply_edits(sample, params)) |> judge()}
    end
  end

  def handle_event("load_players", %{"server_id" => ""}, socket) do
    {:noreply, assign(socket, live_server_id: nil, players: [], sample: nil, diagnosis: nil)}
  end

  def handle_event("load_players", %{"server_id" => id}, socket) do
    case Enum.find(socket.assigns.servers, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      server ->
        # A CRCON round trip; the panel shows a loading state meanwhile.
        {:noreply,
         socket
         |> assign(live_server_id: id, players: [], sample: nil, diagnosis: nil, error: nil)
         |> assign(:loading?, true)
         |> start_async(:snapshot, fn -> Snapshot.refresh(server) end)}
    end
  end

  def handle_event("pick_player", %{"player_id" => player_id}, socket) do
    snapshot = socket.assigns.snapshot

    case {socket.assigns.live_server_id, Snapshot.player(snapshot, player_id)} do
      {server_id, %{} = player} when is_binary(server_id) ->
        sample =
          EventEditor.live_sample(
            String.to_integer(server_id),
            socket.assigns.rule.trigger_event,
            player,
            snapshot.gamestate
          )

        {:noreply, socket |> assign(sample: sample, from_saved?: false, error: nil) |> judge()}

      _other ->
        {:noreply, assign(socket, :error, gettext("That player is no longer connected."))}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_async(:snapshot, {:ok, snapshot}, socket) do
    players =
      snapshot
      |> Snapshot.players()
      |> Enum.map(fn {player_id, player} -> {player["name"] || player_id, player_id} end)
      |> Enum.sort()

    error =
      if players == [],
        do: gettext("Nobody is connected to that server right now, or CRCON did not answer.")

    {:noreply,
     assign(socket, loading?: false, players: players, snapshot: snapshot, error: error)}
  end

  def handle_async(:snapshot, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       loading?: false,
       error: gettext("CRCON did not answer. Try again in a moment.")
     )}
  end

  # A new trigger makes the chosen event meaningless.
  defp drop_stale_sample(%{assigns: %{sample: %{trigger: trigger}, rule: rule}} = socket)
       when trigger != rule.trigger_event,
       do: assign(socket, sample: nil, diagnosis: nil)

  defp drop_stale_sample(socket), do: socket

  defp judge(%{assigns: %{sample: nil}} = socket), do: assign(socket, :diagnosis, nil)

  defp judge(socket) do
    %{sample: sample, rule: rule, servers: servers} = socket.assigns

    case Enum.find(servers, &(&1.id == sample.server_id)) do
      nil ->
        assign(socket, sample: nil, diagnosis: nil)

      server ->
        context = EventEditor.to_context(%{sample | trigger: rule.trigger_event}, server)
        opts = if socket.assigns.from_saved?, do: [at: sample.at], else: []
        assign(socket, :diagnosis, Diagnosis.diagnose(rule, context, opts))
    end
  end

  # The servers the rule would run on.
  defp scope_servers(servers, rule) do
    Enum.filter(servers, fn server ->
      server.game == rule.game and (is_nil(rule.server_id) or server.id == rule.server_id)
    end)
  end

  defp server_name(servers, id) do
    Enum.find_value(servers, fn server -> server.id == id && server.name end)
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.card
        title={gettext("Try it")}
        icon="hero-play-circle"
        subtitle={
          gettext(
            "Evaluates the rule as typed here, including unsaved changes, against a saved event or a player connected right now. Nothing is sent to the game."
          )
        }
      >
        <div class="space-y-3">
          <.segmented_buttons target={@myself} mode={@mode} />

          <form
            :if={@mode == "saved"}
            id="try-it-event-picker"
            phx-change="pick_event"
            phx-target={@myself}
          >
            <p :if={@events == []} class="text-sm text-subtle">
              {gettext(
                "No saved \"%{trigger}\" event yet on these servers. Events are saved as they happen.",
                trigger: Labels.trigger(@rule.trigger_event)
              )}
            </p>
            <label :if={@events != []}>
              <span class="sr-only">{gettext("Pick a saved event")}</span>
              <select name="event_id" class="pc-text-input w-full">
                <option value="">{gettext("Pick a saved event")}</option>
                <option :for={event <- @events} value={event.id}>
                  {sample_label(event.sample, server_name(@servers, event.server_id))}
                </option>
              </select>
            </label>
          </form>

          <div :if={@mode == "live"} class="space-y-2">
            <form id="test-server-picker" phx-change="load_players" phx-target={@myself}>
              <label>
                <span class="sr-only">{gettext("Pick a server")}</span>
                <select name="server_id" class="pc-text-input w-full">
                  <option value="">{gettext("Pick a server")}</option>
                  <option
                    :for={server <- Enum.filter(@servers, &(&1.game == @game))}
                    value={server.id}
                    selected={@live_server_id == to_string(server.id)}
                  >
                    {server.name}
                  </option>
                </select>
              </label>
            </form>
            <.skeleton :if={@loading?} lines={2} />
            <form
              :if={@players != []}
              id="test-player-picker"
              phx-change="pick_player"
              phx-target={@myself}
            >
              <label>
                <span class="sr-only">{gettext("Pick a player")}</span>
                <select name="player_id" class="pc-text-input w-full">
                  <option value="">{gettext("Pick a player")}</option>
                  <option :for={{name, id} <- @players} value={id}>{name}</option>
                </select>
              </label>
            </form>
          </div>

          <.alert :if={@error} color="warning" variant="soft" with_icon label={@error} />
          <.event_fields :if={@sample} id="try-it-fields" sample={@sample} target={@myself} />
          <.diagnosis :if={@diagnosis} diagnosis={@diagnosis} player={@sample.player_name} />
        </div>
      </.card>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :mode, :string, required: true

  defp segmented_buttons(assigns) do
    ~H"""
    <div class="flex gap-1 rounded-box bg-base-200 p-1 text-xs" role="tablist">
      <button
        :for={
          {mode, label} <- [
            {"saved", gettext("Saved events")},
            {"live", gettext("Connected player")}
          ]
        }
        type="button"
        role="tab"
        aria-selected={to_string(@mode == mode)}
        phx-click="mode"
        phx-value-mode={mode}
        phx-target={@target}
        class={[
          "flex-1 rounded-field px-2 py-1 transition",
          if(@mode == mode,
            do: "bg-base-100 font-medium shadow-sm",
            else: "text-subtle hover:text-base-content"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end
end
