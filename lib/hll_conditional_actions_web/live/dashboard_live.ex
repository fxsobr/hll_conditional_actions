defmodule HllConditionalActionsWeb.DashboardLive do
  @moduledoc """
  Fleet overview: one card per CRCON server with its live stream status, rule
  count and the rules that fired most recently.
  """

  use HllConditionalActionsWeb, :live_view

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine.Runner
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  @refresh_ms :timer.seconds(10)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Servers.subscribe()

      Enum.each(
        Servers.list_servers_for(socket.assigns[:current_user]),
        &LogStream.subscribe(&1.id)
      )

      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok, socket |> assign(:page_title, gettext("Overview")) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, server_id, status}, socket) do
    {:noreply, update(socket, :stream_status, &Map.put(&1, server_id, status))}
  end

  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({event, _server}, socket)
      when event in [:server_created, :server_updated, :server_deleted] do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Every authenticated user lands here, so this page has no permission of its
  # own. That makes what it *loads* the only gate: a role without
  # `:view_servers` must not learn the names of the servers from the dashboard
  # when `/servers` would refuse to show them.
  defp load(socket) do
    servers = visible_servers(socket)

    socket
    |> assign(:servers, servers)
    |> assign(:stream_status, Map.new(servers, &{&1.id, LogStream.status(&1.id)}))
    |> assign(:runner_info, Map.new(servers, &{&1.id, Runner.info(&1.id)}))
    |> assign(:recent, recent_executions(socket))
  end

  defp visible_servers(socket) do
    if Accounts.can?(socket.assigns[:current_user], :view_servers) do
      Servers.list_servers_for(socket.assigns[:current_user])
    else
      []
    end
  end

  defp recent_executions(socket) do
    if Accounts.can?(socket.assigns[:current_user], :view_executions) do
      Rules.list_executions_for(socket.assigns[:current_user], limit: 8)
    else
      []
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={@page_title}
      page_subtitle={gettext("Your servers, and what the rules are doing on them")}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_servers)}
          link_type="live_redirect"
          to={~p"/servers/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("Add server")}
        />
      </:actions>

      <%!-- "No servers yet" would be a lie to somebody whose role simply does
            not let them see the ones that exist. --%>
      <.empty_state
        :if={@servers == [] and Accounts.can?(@current_user, :view_servers)}
        icon="hero-server-stack"
        title={gettext("No servers yet")}
        description={
          gettext(
            "Connect a CRCON instance to start reacting to what happens on your Hell Let Loose servers."
          )
        }
      >
        <:action>
          <.button
            :if={Accounts.can?(@current_user, :manage_servers)}
            link_type="live_redirect"
            to={~p"/servers/new"}
            size="sm"
            color="primary"
            label={gettext("Add your first server")}
          />
        </:action>
      </.empty_state>

      <div :if={@servers != []} class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat
          icon="hero-server-stack"
          label={gettext("Servers")}
          value={length(@servers)}
          hint={
            gettext("%{count} connected", count: count_status(@stream_status, @servers, :connected))
          }
        />
        <.stat
          icon="hero-bolt"
          label={gettext("Active rules")}
          value={total_rules(@runner_info)}
          tone="primary"
          hint={gettext("across every running engine")}
        />
        <.stat
          icon="hero-signal"
          label={gettext("Live streams")}
          value={count_status(@stream_status, @servers, :connected)}
          hint={stream_hint(@stream_status, @servers)}
          tone={
            if count_status(@stream_status, @servers, :connected) == count_enabled(@servers),
              do: "success",
              else: "warning"
          }
        />
        <.stat
          icon="hero-clock"
          label={gettext("Latest activity")}
          hint={gettext("last rule that fired")}
        >
          <%= if @recent == [] do %>
            –
          <% else %>
            <.local_time
              id="latest-activity"
              at={hd(@recent).executed_at}
              class="text-lg font-semibold"
            />
          <% end %>
        </.stat>
      </div>

      <div :if={@servers != []} class="grid gap-4 lg:grid-cols-3">
        <div class="space-y-3 lg:col-span-2">
          <h2 class="text-label-medium text-muted">{gettext("Servers")}</h2>

          <div class="grid gap-4 sm:grid-cols-2">
            <.link
              :for={server <- @servers}
              navigate={~p"/servers/#{server}"}
              class="group overflow-hidden rounded-box border border-base-300 bg-base-100 transition-shadow hover:shadow-md"
            >
              <figure class="relative h-24" aria-hidden="true">
                <img
                  src={server_art(server)}
                  alt=""
                  class="size-full object-cover transition-transform duration-200 group-hover:scale-[1.03]"
                  loading="lazy"
                />
                <div class="absolute inset-0 bg-gradient-to-t from-base-100 via-base-100/25 to-transparent">
                </div>
              </figure>

              <div class="-mt-6 flex flex-col gap-3 p-4">
                <div class="relative flex items-start justify-between gap-2">
                  <div class="min-w-0">
                    <h3 class="truncate text-title-large leading-tight">{server.name}</h3>

                    <p class="truncate text-xs text-muted">{Labels.game(server.game)}</p>
                  </div>
                  <.stream_badge status={@stream_status[server.id]} enabled={server.enabled} />
                </div>

                <div class="flex items-center justify-between gap-2">
                  <span class="flex items-center gap-1.5 text-sm text-subtle">
                    <.icon name="hero-bolt" class="size-4 text-muted" />
                    {rule_count(@runner_info[server.id])}
                  </span>

                  <span class="flex items-center gap-1 text-sm text-primary opacity-0 transition-opacity group-hover:opacity-100">
                    {gettext("Details")}
                    <.icon name="hero-arrow-right" class="size-3.5" />
                  </span>
                </div>
              </div>
            </.link>
          </div>
        </div>

        <div :if={@recent != []} class="space-y-3">
          <div class="flex items-baseline justify-between gap-2">
            <h2 class="text-label-medium text-muted">{gettext("Latest rule activity")}</h2>

            <.link
              navigate={~p"/executions"}
              class="text-xs text-muted hover:text-primary hover:underline"
            >
              {gettext("See all")}
            </.link>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100">
            <ul class="divide-y divide-base-300">
              <li :for={execution <- @recent} class="flex items-start gap-2.5 p-3">
                <.status_dot
                  tone={execution_tone(execution.status)}
                  label={Labels.execution_status(execution.status)}
                  class="mt-1.5"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-medium leading-tight">{execution.rule.name}</p>

                  <p class="truncate text-xs text-muted">
                    {execution.player_name || gettext("server wide")} · {execution.server.name}
                  </p>
                </div>

                <.local_time
                  id={"recent-#{execution.id}-at"}
                  at={execution.executed_at}
                  class="shrink-0 text-xs text-muted"
                />
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The tone a finished execution reads in, shared with the history page.
  defp execution_tone(:executed), do: "success"
  defp execution_tone(:partial), do: "warning"
  defp execution_tone(:failed), do: "error"
  defp execution_tone(:simulated), do: "info"
  defp execution_tone(_status), do: "neutral"

  # ── Numbers for the tiles ──────────────────────────────────────────────────

  defp count_status(stream_status, servers, wanted) do
    Enum.count(servers, &(&1.enabled and stream_status[&1.id] == wanted))
  end

  defp count_enabled(servers), do: Enum.count(servers, & &1.enabled)

  defp total_rules(runner_info) do
    runner_info
    |> Map.values()
    |> Enum.map(fn
      %{rules: count} -> count
      _offline -> 0
    end)
    |> Enum.sum()
  end

  defp stream_hint(stream_status, servers) do
    enabled = count_enabled(servers)
    connected = count_status(stream_status, servers, :connected)

    if connected == enabled do
      gettext("all enabled servers")
    else
      gettext("%{count} not connected", count: enabled - connected)
    end
  end

  attr :status, :any, default: nil
  attr :enabled, :boolean, default: true

  defp stream_badge(assigns) do
    ~H"""
    <.tone_badge :if={not @enabled} tone="ghost">{gettext("Disabled")}</.tone_badge>
    <.tone_badge :if={@enabled} tone={stream_badge_tone(@status)}>
      <span :if={@status == :connected} class="size-1.5 rounded-full bg-current"></span> {Labels.stream_status(
        @status
      )}
    </.tone_badge>
    """
  end

  defp stream_badge_tone(:connected), do: "success"
  defp stream_badge_tone(:connecting), do: "warning"
  defp stream_badge_tone({:error, _reason}), do: "error"
  defp stream_badge_tone(_status), do: "ghost"

  defp rule_count(%{rules: count}),
    do: ngettext("%{count} active rule", "%{count} active rules", count, count: count)

  defp rule_count(_info), do: gettext("engine offline")
end
