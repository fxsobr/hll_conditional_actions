defmodule HllConditionalActionsWeb.AttentionLive do
  @moduledoc """
  The attention inbox: everything that needs an admin now, most urgent
  first, with the one link that deals with it. See
  `HllConditionalActions.Attention` for where the items come from.

  It refreshes on its own - a stream reconnecting or a rule firing changes
  what is open - and an item marked as handled leaves for everybody.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Attention
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Engine
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets

  @refresh_ms :timer.seconds(30)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    all = Servers.list_servers_for(socket.assigns.current_user)

    # Under /servers/:id the inbox is that server's only.
    servers =
      case Enum.find(all, &(to_string(&1.id) == params["server_id"])) do
        nil -> all
        server -> [server]
      end

    if connected?(socket) do
      LogStream.subscribe_status()
      Tickets.subscribe()
      Enum.each(servers, &Engine.subscribe(&1.id))
      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Attention"))
     |> assign(:servers, servers)
     |> assign(:filter, "all")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("resolve", %{"key" => key}, socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_rules) do
      Attention.resolve(key, socket.assigns.current_user)
      {:noreply, socket |> put_flash(:info, gettext("Marked as handled.")) |> load()}
    else
      {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, _server_id, _status}, socket),
    do: {:noreply, load(socket)}

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, load(socket)}
  def handle_info({:ticket_changed, _ticket}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    servers = socket.assigns.servers
    stream_status = Map.new(servers, &{&1.id, LogStream.status(&1.id)})

    %{open: open, handled: handled} =
      Attention.items(socket.assigns.current_user, servers, stream_status)

    socket
    |> assign(open: open, handled: handled)
    |> refresh_bell()
  end

  # Handling an item here takes it off the header's bell at once, which
  # counts the whole organisation even on one server's inbox.
  defp refresh_bell(%{assigns: %{nav: %{attention: count} = nav}} = socket)
       when is_integer(count) do
    user = socket.assigns.current_user
    servers = HllConditionalActions.Servers.list_servers_for(user)
    statuses = Map.new(servers, &{&1.id, LogStream.status(&1.id)})
    assign(socket, :nav, %{nav | attention: Attention.count(user, servers, statuses)})
  end

  defp refresh_bell(socket), do: socket

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :shown, filtered(assigns.open, assigns.filter))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("What needs an admin now, most urgent first")}
    >
      <div id="attention-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat
          icon="hero-exclamation-triangle"
          tone={if count(@open, :error) > 0, do: "error", else: "neutral"}
          label={gettext("Urgent")}
          value={count(@open, :error)}
          hint={gettext("broken streams and rules")}
        />
        <.stat
          icon="hero-eye"
          tone={if count(@open, :warning) > 0, do: "warning", else: "neutral"}
          label={gettext("To review")}
          value={count(@open, :warning)}
          hint={gettext("players and failures to look at")}
        />
        <.stat
          icon="hero-light-bulb"
          tone="info"
          label={gettext("Suggestions")}
          value={count(@open, :info)}
          hint={gettext("rules to go live or to check")}
        />
        <.stat
          icon="hero-check-circle"
          tone="success"
          label={gettext("Handled")}
          value={@handled}
          hint={gettext("marked as done by an admin")}
        />
      </div>

      <nav
        :if={@open != []}
        id="attention-filter"
        aria-label={gettext("Filter")}
        class="flex w-fit gap-1 rounded-box bg-base-100 p-1 shadow-figma-card"
      >
        <button
          :for={
            {key, label} <- [
              {"all", gettext("All")},
              {"error", gettext("Urgent")},
              {"warning", gettext("To review")},
              {"info", gettext("Suggestions")}
            ]
          }
          type="button"
          phx-click="filter"
          phx-value-filter={key}
          class={[
            "cursor-pointer rounded-field px-3 py-1.5 text-sm transition-colors",
            if(@filter == key,
              do: "bg-primary font-medium text-primary-content",
              else: "text-subtle hover:bg-base-200"
            )
          ]}
        >
          {label}
        </button>
      </nav>

      <.empty_state
        :if={@open == []}
        icon="hero-sparkles"
        title={gettext("All clear")}
        description={gettext("Nothing needs you right now. New items show up here on their own.")}
      />

      <ul :if={@open != []} id="attention-items" class="space-y-2">
        <li
          :for={item <- @shown}
          id={"attention-#{item_dom_id(item.key)}"}
          class="attention-item"
          data-severity={item.severity}
        >
          <span class="attention-icon">
            <.icon name={item_icon(item)} class="size-5" />
          </span>

          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <p class="font-medium">{title(item)}</p>
              <.local_time
                :if={item.at}
                id={"attention-#{item_dom_id(item.key)}-at"}
                at={item.at}
                class="text-xs text-muted"
              />
            </div>
            <p class="mt-0.5 text-sm break-words text-subtle">{detail(item)}</p>
          </div>

          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <.button
              link_type="live_redirect"
              to={item_path(item)}
              size="xs"
              variant="outline"
              color="gray"
              label={link_label(item)}
            />
            <.button
              :if={item.resolvable? and Accounts.can?(@current_user, :manage_rules)}
              type="button"
              size="xs"
              color="primary"
              icon="hero-check"
              phx-click="resolve"
              phx-value-key={item.key}
              label={gettext("Handled")}
            />
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp filtered(items, "all"), do: items
  defp filtered(items, severity), do: Enum.filter(items, &(to_string(&1.severity) == severity))

  defp count(items, severity), do: Enum.count(items, &(&1.severity == severity))

  defp item_dom_id(key), do: String.replace(key, ~r/[^a-z0-9_-]/i, "-")

  defp item_icon(%{kind: :stream_down}), do: "hero-signal-slash"
  defp item_icon(%{kind: :ticket_waiting}), do: "hero-chat-bubble-left-ellipsis"
  defp item_icon(%{kind: :rule_broken}), do: "hero-no-symbol"
  defp item_icon(%{kind: :failures}), do: "hero-x-circle"
  defp item_icon(%{kind: :review}), do: "hero-eye"
  defp item_icon(%{kind: :ready_to_go_live}), do: "hero-rocket-launch"
  defp item_icon(%{kind: :rule_quiet}), do: "hero-moon"

  defp title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do:
      gettext("%{player} is waiting for an admin",
        player: ticket.player_name || ticket.player_id
      )

  defp title(%{kind: :stream_down, subject: %{server: server}}),
    do: gettext("%{server} is not streaming events", server: server.name)

  defp title(%{kind: kind, subject: %{rule: rule, issue: issue}})
       when kind in [:rule_broken, :rule_quiet],
       do: "#{rule.name} · #{Labels.health_issue(issue.id)}"

  defp title(%{kind: :failures, subject: %{rule: rule, count: count}}),
    do:
      ngettext("%{rule} failed once today", "%{rule} failed %{count} times today", count,
        rule: rule.name
      )

  defp title(%{kind: :review, subject: %{execution: execution}}),
    do:
      gettext("Review %{player}",
        player: execution.player_name || execution.player_id
      )

  defp title(%{kind: :ready_to_go_live, subject: %{rule: rule}}),
    do: gettext("%{rule} looks ready to go live", rule: rule.name)

  defp detail(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: gettext("Ticket on %{server} with no answer yet.", server: ticket.server.name)

  defp detail(%{kind: :stream_down, subject: %{reason: :stopped}}),
    do:
      gettext(
        "The engine for this server stopped. It starts again on its own within a minute; if it does not, save the server again."
      )

  defp detail(%{kind: :stream_down, subject: %{reason: reason}}),
    do:
      gettext("No rule can react to this server until it is back. CRCON said: %{reason}",
        reason: reason
      )

  defp detail(%{kind: kind, subject: %{issue: issue}}) when kind in [:rule_broken, :rule_quiet],
    do: Labels.health_explanation(issue.id)

  defp detail(%{kind: :failures, subject: %{error: error}}),
    do: gettext("Latest error: %{error}", error: error || gettext("unknown"))

  defp detail(%{kind: :review, subject: %{execution: execution, reason: reason}}),
    do: "#{execution.rule.name} · #{execution.server.name} · #{reason}"

  defp detail(%{kind: :ready_to_go_live, subject: %{runs: runs}}),
    do:
      gettext(
        "It has been simulating for days, %{runs} recorded runs and no failure. Read what it would have done, then turn simulation off.",
        runs: runs
      )

  defp item_path(%{kind: :stream_down, subject: %{server: server}}), do: ~p"/servers/#{server}"

  defp item_path(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: ~p"/tickets/#{ticket.id}"

  defp item_path(%{kind: :review, subject: %{execution: execution}}),
    do: ~p"/players/#{execution.player_id}"

  defp item_path(%{subject: %{rule: rule}}), do: ~p"/rules/#{rule.id}"

  defp link_label(%{kind: :stream_down}), do: gettext("Open the server")
  defp link_label(%{kind: :ticket_waiting}), do: gettext("Answer")
  defp link_label(%{kind: :review}), do: gettext("Open the player")
  defp link_label(_item), do: gettext("Open the rule")
end
