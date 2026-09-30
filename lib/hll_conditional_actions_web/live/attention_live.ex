defmodule HllConditionalActionsWeb.AttentionLive do
  @moduledoc """
  The attention inbox: everything that needs an admin now, most urgent
  first, with the one link that deals with it. See
  `HllConditionalActions.Attention` for where the items come from.

  It refreshes on its own - a stream reconnecting or a rule firing changes
  what is open - and an item marked as handled leaves for everybody.

  The Caixa (`HllConditionalActionsWeb.InboxLive`) shows the same items next
  to the tickets; the words, icons and links of an item live here
  (`item_title/1`, `item_detail/1`, `item_path/1`…) and serve both pages.
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
  @filters ~w(all error warning info)

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
      # Users who may read tickets get ticket changes through
      # `HllConditionalActionsWeb.Nav` already; subscribing again would
      # deliver each change twice.
      unless Accounts.can?(socket.assigns.current_user, :view_tickets), do: Tickets.subscribe()
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
    filter = Enum.find(@filters, "all", &(&1 == filter))
    {:noreply, socket |> assign(:filter, filter) |> load()}
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

    shown = filtered(open, socket.assigns.filter)

    socket
    |> assign(:handled, handled)
    |> assign(:counts, %{
      total: length(open),
      error: count(open, :error),
      warning: count(open, :warning),
      info: count(open, :info)
    })
    |> assign(:shown_count, length(shown))
    |> stream(:items, shown, reset: true, dom_id: &"attention-#{item_dom_id(&1.key)}")
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
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("What needs an admin now, most urgent first")}
    >
      <:actions>
        <.link
          navigate={~p"/inbox"}
          class="inline-flex h-9 items-center gap-1.5 rounded-full px-3 text-sm text-subtle transition-colors hover:bg-base-100 hover:text-base-content"
        >
          <.icon name="hero-inbox" class="size-4" /> {gettext("Open the inbox")}
        </.link>
      </:actions>

      <section
        id="attention-kpis"
        class="grid gap-3 rounded-[1.75rem] bg-base-100 p-3 sm:grid-cols-2 xl:grid-cols-4"
      >
        <.kpi_tile
          label={gettext("Urgent")}
          value={@counts.error}
          tone={if @counts.error > 0, do: "error"}
          hint={gettext("broken streams and rules")}
        />
        <.kpi_tile
          label={gettext("To review")}
          value={@counts.warning}
          tone={if @counts.warning > 0, do: "warning"}
          hint={gettext("players and failures to look at")}
        />
        <.kpi_tile
          label={gettext("Suggestions")}
          value={@counts.info}
          tone={if @counts.info > 0, do: "engine"}
          hint={gettext("rules to go live or to check")}
        />
        <.kpi_tile
          label={gettext("Handled")}
          value={@handled}
          tone="primary"
          hint={gettext("marked as done by an admin")}
        />
      </section>

      <.empty_state
        :if={@counts.total == 0}
        icon="hero-sparkles"
        title={gettext("All clear")}
        description={gettext("Nothing needs you right now. New items show up here on their own.")}
      />

      <section :if={@counts.total > 0} class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 p-4">
        <nav
          id="attention-filter"
          aria-label={gettext("Filter")}
          class="flex flex-wrap gap-1.5 px-1 pt-1"
        >
          <button
            :for={
              {key, label, count} <- [
                {"all", gettext("All"), @counts.total},
                {"error", gettext("Urgent"), @counts.error},
                {"warning", gettext("To review"), @counts.warning},
                {"info", gettext("Suggestions"), @counts.info}
              ]
            }
            type="button"
            phx-click="filter"
            phx-value-filter={key}
            aria-pressed={to_string(@filter == key)}
            class={[
              "inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-full border px-3 text-xs transition-colors",
              cond do
                @filter == key and key == "error" ->
                  "border-error/40 bg-error/10 font-semibold text-error"

                @filter == key ->
                  "border-base-content bg-base-content font-semibold text-base-100"

                true ->
                  "border-base-300 bg-secondary hover:border-base-content/30"
              end
            ]}
          >
            {label} <span class="font-mono opacity-70">{count}</span>
          </button>
        </nav>

        <ul id="attention-items" phx-update="stream" class="flex flex-col gap-1">
          <li
            id="attention-items-empty"
            class="hidden px-3 py-8 text-center text-sm text-muted only:block"
          >
            {gettext("Nothing in this filter.")}
          </li>
          <li
            :for={{dom_id, item} <- @streams.items}
            id={dom_id}
            data-severity={item.severity}
            class="flex flex-wrap items-start gap-3.5 rounded-[1.125rem] p-3 transition-colors hover:bg-secondary sm:flex-nowrap"
          >
            <.icon_tile icon={item_icon(item)} tone={item_tone(item)} />

            <div class="min-w-0 flex-1 basis-60">
              <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5">
                <p class="font-semibold">{item_title(item)}</p>
                <.local_time
                  :if={item.at}
                  id={"#{dom_id}-at"}
                  at={item.at}
                  class={[
                    "font-mono text-[0.6875rem]",
                    if(item.severity == :error, do: "text-error", else: "text-muted")
                  ]}
                />
              </div>
              <p class="mt-0.5 break-words text-[0.8125rem] text-subtle">{item_detail(item)}</p>
            </div>

            <div class="flex shrink-0 flex-wrap items-center gap-2 max-sm:ml-[3.375rem]">
              <.link
                navigate={~p"/inbox?#{[item: item.key]}"}
                class="inline-flex h-8 items-center rounded-full px-3 text-xs text-subtle transition-colors hover:bg-base-100 hover:text-base-content"
              >
                {gettext("Details")}
              </.link>
              <.button
                link_type="live_redirect"
                to={item_path(item)}
                size="xs"
                variant="outline"
                color="gray"
                label={item_link_label(item)}
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
      </section>
    </Layouts.app>
    """
  end

  defp filtered(items, "all"), do: items
  defp filtered(items, severity), do: Enum.filter(items, &(to_string(&1.severity) == severity))

  defp count(items, severity), do: Enum.count(items, &(&1.severity == severity))

  # ── An item, in words ──────────────────────────────────────────────────────

  @doc """
  A key as a DOM id fragment.

      iex> HllConditionalActionsWeb.AttentionLive.item_dom_id("health:quiet:12")
      "health-quiet-12"
  """
  @spec item_dom_id(String.t()) :: String.t()
  def item_dom_id(key), do: String.replace(key, ~r/[^a-z0-9_-]/i, "-")

  @doc "The icon of an item."
  @spec item_icon(map()) :: String.t()
  def item_icon(%{kind: :stream_down}), do: "hero-signal-slash"
  def item_icon(%{kind: :ticket_waiting}), do: "hero-chat-bubble-left-ellipsis"
  def item_icon(%{kind: :rule_broken}), do: "hero-no-symbol"
  def item_icon(%{kind: :failures}), do: "hero-bolt"
  def item_icon(%{kind: :review}), do: "hero-eye"
  def item_icon(%{kind: :ready_to_go_live}), do: "hero-rocket-launch"
  def item_icon(%{kind: :rule_quiet}), do: "hero-moon"
  def item_icon(%{kind: :vip_failed}), do: "hero-shopping-bag"
  def item_icon(_item), do: "hero-bell-alert"

  @doc "The tile tone of an item: red when urgent, amber to review, lime for a suggestion."
  @spec item_tone(map()) :: String.t()
  def item_tone(%{severity: :error}), do: "error"
  def item_tone(%{kind: :review}), do: "axis"
  def item_tone(%{severity: :warning}), do: "warning"
  def item_tone(%{kind: :ready_to_go_live}), do: "primary"
  def item_tone(_info), do: "engine"

  @doc "What an item is about, in one line."
  @spec item_title(map()) :: String.t()
  def item_title(%{kind: :vip_failed, subject: %{order: order}}),
    do:
      gettext("Paid VIP not granted for %{player}",
        player: order.player_name || order.player_id
      )

  def item_title(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do:
      gettext("%{player} is waiting for an admin",
        player: ticket.player_name || ticket.player_id
      )

  def item_title(%{kind: :stream_down, subject: %{server: server}}),
    do: gettext("%{server} is not streaming events", server: server.name)

  def item_title(%{kind: kind, subject: %{rule: rule, issue: issue}})
      when kind in [:rule_broken, :rule_quiet],
      do: "#{rule.name} · #{Labels.health_issue(issue.id)}"

  def item_title(%{kind: :failures, subject: %{rule: rule, count: count}}),
    do:
      ngettext("%{rule} failed once today", "%{rule} failed %{count} times today", count,
        rule: rule.name
      )

  def item_title(%{kind: :review, subject: %{execution: execution}}),
    do:
      gettext("Review %{player}",
        player: execution.player_name || execution.player_id
      )

  def item_title(%{kind: :ready_to_go_live, subject: %{rule: rule}}),
    do: gettext("%{rule} looks ready to go live", rule: rule.name)

  @doc "The line of context under an item's title."
  @spec item_detail(map()) :: String.t()
  def item_detail(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: gettext("Ticket on %{server} with no answer yet.", server: ticket.server.name)

  def item_detail(%{kind: :stream_down, subject: %{reason: :stopped}}),
    do:
      gettext(
        "The engine for this server stopped. It starts again on its own within a minute; if it does not, save the server again."
      )

  def item_detail(%{kind: :stream_down, subject: %{reason: reason}}),
    do:
      gettext("No rule can react to this server until it is back. CRCON said: %{reason}",
        reason: reason
      )

  def item_detail(%{kind: kind, subject: %{issue: issue}})
      when kind in [:rule_broken, :rule_quiet],
      do: Labels.health_explanation(issue.id)

  def item_detail(%{kind: :vip_failed, subject: %{order: order}}),
    do:
      gettext("Order #%{id}, %{package}. Failed on: %{servers}",
        id: order.id,
        package: order.package_name,
        servers:
          order.grants
          |> Enum.filter(&(&1.status == "failed"))
          |> Enum.map_join(", ", & &1.server_name)
      )

  def item_detail(%{kind: :failures, subject: %{error: error}}),
    do: gettext("Latest error: %{error}", error: error || gettext("unknown"))

  def item_detail(%{kind: :review, subject: %{execution: execution, reason: reason}}),
    do: "#{execution.rule.name} · #{execution.server.name} · #{reason}"

  def item_detail(%{kind: :ready_to_go_live, subject: %{runs: runs}}),
    do:
      gettext(
        "It has been simulating for days, %{runs} recorded runs and no failure. Read what it would have done, then turn simulation off.",
        runs: runs
      )

  @doc "Where an item is dealt with."
  @spec item_path(map()) :: String.t()
  def item_path(%{kind: :stream_down, subject: %{server: server}}), do: ~p"/servers/#{server}"

  def item_path(%{kind: :ticket_waiting, subject: %{ticket: ticket}}),
    do: ~p"/tickets/#{ticket.id}"

  def item_path(%{kind: :review, subject: %{execution: execution}}),
    do: ~p"/players/#{execution.player_id}"

  def item_path(%{kind: :vip_failed}), do: ~p"/vip-shop/purchases"
  def item_path(%{subject: %{rule: rule}}), do: ~p"/rules/#{rule.id}"

  @doc "The words of the link to `item_path/1`."
  @spec item_link_label(map()) :: String.t()
  def item_link_label(%{kind: :stream_down}), do: gettext("Open the server")
  def item_link_label(%{kind: :ticket_waiting}), do: gettext("Answer")
  def item_link_label(%{kind: :review}), do: gettext("Open the player")
  def item_link_label(%{kind: :vip_failed}), do: gettext("Open the purchases")
  def item_link_label(_item), do: gettext("Open the rule")
end
