defmodule HllConditionalActionsWeb.SettingsLive do
  @moduledoc """
  Ajustes: the hub for servers, people, integrations, the engine and the
  signed in account (the Settings board).

  Every card is a door to a page that already exists, and each one shows
  only when the signed in user may open that page — the same permission the
  page itself enforces on mount. The line under each title is read from the
  data behind it (how many servers, which stream is down, who has no second
  factor, how many sessions are open), so the hub already answers "is
  anything wrong here?" before a click.

  The search in the header filters the doors as you type ("/" focuses it).

  The server tiles show what each server is playing through the Briefing's
  cached `LiveStatus`, read after the first render so a slow CRCON never
  holds the page.

  Preferences are the ones the app has: the language (the session locale,
  through `/locale/:locale`) and the colour scheme (Petal's, kept in the
  browser). The version card is shown to whoever can manage users.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.SettingsComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Enrolments
  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.Briefing.LiveStatus
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Features
  alias HllConditionalActions.Metrics.History
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Updates
  alias HllConditionalActionsWeb.LiveComponents
  alias HllConditionalActionsWeb.Nav
  alias HllConditionalActionsWeb.Plugs.Locale

  # The hub shows this many server tiles; "Gerenciar servidores" has them all.
  @tiles 3

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:can, permissions(user))
      |> assign(:query, "")
      |> assign(:live, %{})
      |> assign(:session_id, Sessions.id_for(session["session_token"]))
      |> load()

    socket =
      if connected?(socket) and socket.assigns.servers != [] do
        LogStream.subscribe_status()
        servers = socket.assigns.servers
        start_async(socket, :live, fn -> LiveStatus.fetch(servers) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :query, String.slice(query, 0, 80))}
  end

  def handle_event("check_updates", _params, socket) do
    if socket.assigns.can.manage_users do
      Updates.refresh()
      {:noreply, put_flash(socket, :info, gettext("Checking GitHub for a newer release…"))}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, live}, socket), do: {:noreply, assign(socket, :live, live)}
  def handle_async(:live, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, server_id, status}, socket) do
    {:noreply, update(socket, :stream_status, &Map.put(&1, server_id, status))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp permissions(user) do
    Map.new(
      ~w(view_servers manage_servers manage_users manage_roles manage_integrations view_executions)a,
      &{&1, Accounts.can?(user, &1)}
    )
  end

  defp load(socket) do
    %{can: can, current_user: user} = socket.assigns

    servers =
      if can.view_servers or can.manage_servers, do: Servers.list_servers_for(user), else: []

    socket
    |> assign(:servers, servers)
    |> assign(:stream_status, Map.new(servers, &{&1.id, LogStream.status(&1.id)}))
    |> assign(:users, if(can.manage_users, do: Accounts.list_users(), else: []))
    |> assign(
      :two_factor_ids,
      if(can.manage_users, do: TwoFactor.enabled_user_ids(), else: MapSet.new())
    )
    |> assign(:roles, if(can.manage_roles, do: Accounts.list_roles(), else: []))
    |> assign(:webhooks, if(can.manage_integrations, do: Discord.list_webhooks(), else: []))
    |> assign(:modules, modules(servers, can))
    |> assign(:engine, if(can.view_executions, do: engine_summary()))
    |> assign(:updates, if(can.manage_users, do: Updates.status()))
    |> assign(:sessions_open, length(Sessions.list(user)))
    |> assign(:two_factor, two_factor_state(user))
  end

  defp modules(servers, %{manage_servers: true}) when servers != [] do
    servers |> Enum.map(& &1.id) |> Features.installed_by_server()
  end

  defp modules(_servers, _can), do: %{}

  defp two_factor_state(user) do
    cond do
      TwoFactor.enabled?(user) -> :on
      Enrolments.pending(user) -> :pending
      true -> :off
    end
  end

  # The line under "Métricas": p95 and the engine's queue over the last hour.
  defp engine_summary, do: History.hub_summary()

  defp stream_down_since(server_id), do: History.stream_down_since(server_id)

  # ── Search ─────────────────────────────────────────────────────────────────

  defp normalize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.trim()
  end

  # A door shows when the query is empty or any of its words contains it.
  defp shown?("", _terms), do: true

  defp shown?(query, terms) do
    query = normalize(query)
    Enum.any?(terms, &String.contains?(normalize(&1), query))
  end

  defp terms(:servers, servers),
    do:
      [gettext("Servers"), gettext("Manage servers"), "crcon", "servers"] ++
        Enum.map(servers, & &1.name)

  defp terms(:users, _data),
    do: [gettext("People"), gettext("Users"), gettext("accounts"), "2fa", "users", "people"]

  defp terms(:roles, _data),
    do: [gettext("People"), gettext("Roles"), gettext("permissions"), "roles"]

  defp terms(:discord, _data), do: [gettext("Integrations"), "Discord", "webhooks"]

  defp terms(:payments, _data),
    do: [gettext("Integrations"), gettext("Payments and email"), "e-mail", "pix", "vip"]

  defp terms(:metrics, _data), do: ["Engine", gettext("Metrics"), "p95", "crcon", "metrics"]
  defp terms(:modules, _data), do: ["Engine", gettext("Modules"), "modules", "marketplace"]

  defp terms(:account, user),
    do: [
      gettext("My account"),
      gettext("Sessions"),
      gettext("Password"),
      "2fa",
      user.username,
      user.name || ""
    ]

  defp terms(:preferences, _data),
    do: [
      gettext("Preferences"),
      gettext("Language"),
      gettext("Theme"),
      gettext("Light"),
      gettext("Dark"),
      gettext("Show times in"),
      "English",
      "Español",
      "Português"
    ]

  defp terms(:about, _data),
    do: [gettext("About"), gettext("Installed"), gettext("Release notes"), gettext("Update")]

  # ── Lines under the titles ─────────────────────────────────────────────────

  defp stream_down?(server, stream_status) do
    server.enabled and match?({:error, _}, stream_status[server.id])
  end

  defp stream_down(servers, stream_status),
    do: Enum.count(servers, &stream_down?(&1, stream_status))

  # The servers with a problem first, the rest in the list's order.
  defp tiles(servers, stream_status) do
    indexed = Enum.with_index(servers)

    {down, up} =
      Enum.split_with(indexed, fn {server, _i} -> stream_down?(server, stream_status) end)

    (down ++ up)
    |> Enum.take(@tiles)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp servers_line(servers) do
    count = length(servers)
    games = servers |> Enum.map(& &1.game) |> Enum.uniq()

    case games do
      [game] ->
        ngettext("%{count} %{game} server", "%{count} %{game} servers", count,
          count: count,
          game: game_short(game)
        )

      _mixed ->
        ngettext("%{count} server", "%{count} servers", count, count: count)
    end
  end

  defp game_short(:hll), do: "HLL"
  defp game_short(:hllv), do: "HLL Vietnam"
  defp game_short(game), do: to_string(game)

  defp stream_dot(_status, false), do: "bg-base-300"
  defp stream_dot(:connected, _enabled), do: "bg-primary"
  defp stream_dot(:connecting, _enabled), do: "bg-warning"
  defp stream_dot({:error, _reason}, _enabled), do: "bg-error"
  defp stream_dot(_status, _enabled), do: "bg-muted"

  defp without_two_factor(users, ids) do
    Enum.count(users, &(&1.active and not MapSet.member?(ids, &1.id)))
  end

  defp failing(webhooks), do: Enum.filter(webhooks, & &1.last_error)

  # "1 com erro 404" when every failing webhook failed the same way.
  defp failing_code(webhooks) do
    webhooks
    |> failing()
    |> Enum.map(&http_code(&1.last_error))
    |> Enum.uniq()
    |> case do
      [code] when is_binary(code) -> code
      _mixed -> nil
    end
  end

  defp http_code(error) when is_binary(error) do
    case Regex.run(~r/HTTP (\d{3})/, error) do
      [_all, code] -> code
      nil -> if error =~ ~r/^\d{3}$/, do: error
    end
  end

  defp http_code(_error), do: nil

  defp active_modules(modules) do
    modules |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2) |> MapSet.size()
  end

  defp streams(servers, stream_status) do
    watched = Enum.filter(servers, &(&1.enabled and &1.log_stream_enabled))
    {Enum.count(watched, &(stream_status[&1.id] == :connected)), length(watched)}
  end

  defp people_preview(users, current_user) do
    {me, others} = Enum.split_with(users, &(&1.id == current_user.id))
    me ++ Enum.filter(others, & &1.active)
  end

  defp locale_label("pt_BR"), do: "Português"
  defp locale_label("es"), do: "Español"
  defp locale_label("en"), do: "English"
  defp locale_label(locale), do: locale

  # Português first, as on the board; then whatever else is supported.
  defp locales do
    Enum.sort_by(Locale.supported(), &Enum.find_index(["pt_BR", "en", "es"], fn l -> l == &1 end))
  end

  defp current_locale, do: Gettext.get_locale(HllConditionalActionsWeb.Gettext)

  defp people?(can), do: can.manage_users or can.manage_roles
  defp engine?(can, servers), do: can.view_executions or (can.manage_servers and servers != [])

  # The first lines of the release notes that read as a list, stripped of
  # their markdown: what the "+" list of the About card shows.
  defp note_items(nil), do: []

  defp note_items(%{notes: notes}) when is_binary(notes) do
    notes
    |> String.split(~r/\R/)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*[-*+]\s+(.+)$/, line) do
        [_all, item] ->
          [item |> String.replace(~r/[*_`]|\[([^\]]*)\]\([^)]*\)/, "\\1") |> String.trim()]

        nil ->
          []
      end
    end)
    |> Enum.take(3)
  end

  defp note_items(_release), do: []

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:show, fn key, data -> shown?(assigns.query, terms(key, data)) end)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Settings")}
      page_subtitle={gettext("Servers, people, integrations and the engine behind the rules")}
      bell={false}
      scope={false}
    >
      <:search>
        <form
          id="settings-search-form"
          phx-change="search"
          phx-submit="search"
          role="search"
          class="hidden md:block"
        >
          <label class="flex h-12 w-80 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-muted focus-within:border-primary/60">
            <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
            <input
              id="settings-search"
              name="q"
              value={@query}
              type="search"
              autocomplete="off"
              phx-debounce="100"
              phx-hook=".SlashFocus"
              aria-label={gettext("Search settings")}
              placeholder={gettext("Search settings")}
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-base-content outline-none placeholder:text-muted focus:ring-0"
            />
            <kbd class="rounded-md bg-secondary px-1.5 py-0.5 font-mono text-[0.6875rem] text-muted">
              /
            </kbd>
          </label>
        </form>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SlashFocus">
          export default {
            mounted() {
              this.onKey = (e) => {
                const t = e.target
                const typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))
                if (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) {
                  e.preventDefault()
                  this.el.focus()
                }
                if (e.key === "Escape" && t === this.el) this.el.blur()
              }
              window.addEventListener("keydown", this.onKey)
            },
            destroyed() { window.removeEventListener("keydown", this.onKey) }
          }
        </script>
      </:search>

      <div class="grid gap-5 xl:min-h-[56.25rem] xl:grid-cols-[minmax(0,1fr)_25rem]">
        <div class="grid content-start gap-5 lg:grid-cols-2 xl:grid-rows-[16.75rem_minmax(0,1fr)_minmax(0,1fr)] xl:content-stretch">
          <%!-- ── Servers ─────────────────────────────────────────────── --%>
          <section
            :if={@can.view_servers and @show.(:servers, @servers)}
            id="settings-servers"
            aria-label={gettext("Servers")}
            class="flex flex-col gap-4 rounded-panel bg-base-100 p-[1.375rem] lg:col-span-2"
          >
            <div class="flex flex-wrap items-center gap-3.5">
              <span class="flex size-11 shrink-0 items-center justify-center rounded-[0.875rem] bg-primary/12 text-primary">
                <.icon name="hero-server-stack" class="size-5" />
              </span>
              <div class="flex min-w-0 flex-1 flex-col gap-0.5">
                <h2 class="font-display text-xl font-semibold">{gettext("Servers")}</h2>
                <p class="text-[0.8125rem] text-muted">
                  {servers_line(@servers)}
                  <span :if={stream_down(@servers, @stream_status) > 0} class="text-error">
                    · {ngettext(
                      "%{count} with the stream down",
                      "%{count} with the stream down",
                      stream_down(@servers, @stream_status),
                      count: stream_down(@servers, @stream_status)
                    )}
                  </span>
                </p>
              </div>
              <.link
                id="settings-manage-servers"
                navigate={~p"/servers"}
                class="flex h-10 items-center gap-2 rounded-full border border-base-300 bg-secondary px-4 text-[0.8125rem] transition-colors hover:bg-base-300"
              >
                {gettext("Manage servers")} <.icon name="hero-chevron-right" class="size-3.5" />
              </.link>
            </div>

            <p :if={@servers == []} class="rounded-2xl bg-secondary p-4 text-sm text-subtle">
              {gettext("No server connected yet.")}
              <.link
                :if={@can.manage_servers}
                navigate={~p"/servers/new"}
                class="font-semibold text-primary hover:underline"
              >
                {gettext("Add the first one")}
              </.link>
            </p>

            <div :if={@servers != []} class="grid min-h-0 flex-1 gap-3 sm:grid-cols-3">
              <.link
                :for={server <- tiles(@servers, @stream_status)}
                id={"settings-server-#{server.id}"}
                navigate={~p"/servers/#{server}"}
                class={[
                  "group relative flex min-h-32 flex-col justify-end overflow-hidden rounded-[1.25rem] bg-secondary text-white",
                  stream_down?(server, @stream_status) && "ring-1 ring-inset ring-error/50"
                ]}
              >
                <img
                  src={server_art(server)}
                  alt=""
                  loading="lazy"
                  class="absolute inset-0 size-full object-cover transition-transform duration-300 group-hover:scale-105"
                />
                <span class="settings-art-scrim absolute inset-0" aria-hidden="true"></span>
                <span
                  :if={stream_down?(server, @stream_status)}
                  class="absolute left-3 top-3 rounded-full bg-[rgb(40_16_14/0.85)] px-2.5 py-1 text-[0.6875rem] font-semibold text-[#FF9C95]"
                >
                  <%= if since = stream_down_since(server.id) do %>
                    {gettext("Stream dropped")}
                    <.clock id={"settings-down-#{server.id}"} at={since} />
                  <% else %>
                    {gettext("Stream dropped")}
                  <% end %>
                </span>
                <span class="relative flex flex-col gap-1 px-4 py-3.5">
                  <strong class="truncate text-[0.9375rem] font-semibold">{server.name}</strong>
                  <.tile_line
                    server={server}
                    status={@stream_status[server.id]}
                    live={@live[server.id]}
                  />
                </span>
              </.link>
            </div>
          </section>

          <%!-- ── People ──────────────────────────────────────────────── --%>
          <section
            :if={people?(@can) and (@show.(:users, nil) or @show.(:roles, nil))}
            id="settings-people"
            aria-label={gettext("People")}
            class="flex min-h-0 flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-center justify-between">
              <.section_label>{gettext("People")}</.section_label>
              <span :if={@users != []} class="flex" aria-hidden="true">
                <.person_avatar
                  :for={
                    {person, index} <-
                      Enum.with_index(Enum.take(people_preview(@users, @current_user), 3))
                  }
                  user={person}
                  size="xs"
                  class={["border-2 border-base-100", index > 0 && "-ml-2"]}
                />
                <span
                  :if={length(@users) > 3}
                  class="-ml-2 flex size-7 items-center justify-center rounded-full border-2 border-base-100 bg-secondary text-[0.625rem] font-bold text-subtle"
                >
                  +{length(@users) - 3}
                </span>
              </span>
            </div>

            <.hub_row
              :if={@can.manage_users and @show.(:users, nil)}
              id="settings-users"
              navigate={~p"/users"}
              icon="hero-users"
              title={gettext("Users")}
            >
              {ngettext("%{count} account", "%{count} accounts", length(@users),
                count: length(@users)
              )}
              <span
                :if={without_two_factor(@users, @two_factor_ids) > 0}
                class="text-warning"
              >
                · {ngettext(
                  "%{count} without two factor",
                  "%{count} without two factor",
                  without_two_factor(@users, @two_factor_ids),
                  count: without_two_factor(@users, @two_factor_ids)
                )}
              </span>
            </.hub_row>

            <.hub_row
              :if={@can.manage_roles and @show.(:roles, nil)}
              id="settings-roles"
              navigate={~p"/roles"}
              icon="hero-shield-check"
              title={gettext("Roles")}
            >
              {gettext("%{builtin} built-in · %{custom} custom · %{permissions} permissions",
                builtin: Enum.count(@roles, & &1.system?),
                custom: Enum.count(@roles, &(not &1.system?)),
                permissions: length(Permission.all())
              )}
            </.hub_row>
          </section>

          <%!-- ── Integrations ────────────────────────────────────────── --%>
          <section
            :if={@can.manage_integrations and (@show.(:discord, nil) or @show.(:payments, nil))}
            id="settings-integrations"
            aria-label={gettext("Integrations")}
            class="flex min-h-0 flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <.section_label>{gettext("Integrations")}</.section_label>

            <.hub_row
              :if={@show.(:discord, nil)}
              id="settings-discord"
              navigate={~p"/discord"}
              icon="hero-chat-bubble-bottom-center-text"
              tone="allies"
              title={gettext("Discord")}
            >
              {ngettext("%{count} webhook", "%{count} webhooks", length(@webhooks),
                count: length(@webhooks)
              )}
              <span :if={failing(@webhooks) != []} class="text-error">
                ·
                <%= if code = failing_code(@webhooks) do %>
                  {ngettext(
                    "%{count} with error %{code}",
                    "%{count} with error %{code}",
                    length(failing(@webhooks)),
                    count: length(failing(@webhooks)),
                    code: code
                  )}
                <% else %>
                  {ngettext("%{count} failing", "%{count} failing", length(failing(@webhooks)),
                    count: length(failing(@webhooks))
                  )}
                <% end %>
              </span>
            </.hub_row>

            <.hub_row
              :if={Nav.feature?(assigns[:nav], :vip_shop) and @show.(:payments, nil)}
              id="settings-vip-shop"
              navigate={~p"/vip-shop/settings"}
              icon="hero-envelope"
              title={gettext("Payments and email")}
              dashed
            >
              {gettext("Set up inside the VIP shop")}
            </.hub_row>
          </section>

          <%!-- ── Engine ──────────────────────────────────────────────── --%>
          <section
            :if={engine?(@can, @servers) and (@show.(:metrics, nil) or @show.(:modules, nil))}
            id="settings-engine"
            aria-label={gettext("Engine")}
            class="flex min-h-0 flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <.section_label>{gettext("Engine")}</.section_label>

            <.hub_row
              :if={@can.view_executions and @show.(:metrics, nil)}
              id="settings-metrics"
              navigate={~p"/metrics"}
              icon="hero-chart-bar"
              tone="engine"
              title={gettext("Metrics")}
            >
              <.engine_line engine={@engine} streams={streams(@servers, @stream_status)} />
            </.hub_row>

            <.hub_row
              :if={@can.manage_servers and @servers != [] and @show.(:modules, nil)}
              id="settings-modules"
              navigate={~p"/servers/#{hd(@servers)}/marketplace"}
              icon="hero-square-3-stack-3d"
              title={gettext("Modules")}
            >
              {ngettext(
                "%{count} active, switched on per server",
                "%{count} active, switched on per server",
                active_modules(@modules),
                count: active_modules(@modules)
              )}
            </.hub_row>
          </section>

          <%!-- ── My account ──────────────────────────────────────────── --%>
          <section
            :if={@show.(:account, @current_user)}
            id="settings-account"
            aria-label={gettext("My account")}
            class="flex min-h-0 flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <.section_label>{gettext("My account")}</.section_label>

            <.hub_row
              id="settings-account-link"
              navigate={~p"/account"}
              title={@current_user.name || @current_user.username}
            >
              <:lead>
                <.person_avatar user={@current_user} />
              </:lead>
              {@current_user.role && @current_user.role.name} · {ngettext(
                "%{count} open session",
                "%{count} open sessions",
                @sessions_open,
                count: @sessions_open
              )}
            </.hub_row>

            <.link
              :if={@two_factor != :on}
              id="settings-two-factor"
              navigate={~p"/account"}
              class="flex items-center gap-3 rounded-[1.125rem] border border-warning/30 bg-warning/10 px-4 py-3 transition-colors hover:bg-warning/15"
            >
              <.icon name="hero-lock-closed" class="size-4 shrink-0 text-warning" />
              <span class="min-w-0 flex-1 text-[0.8125rem]">
                {gettext("Two-step verification")}
                <span class="font-semibold text-warning">
                  {if @two_factor == :pending,
                    do: gettext("being set up"),
                    else: gettext("off")}
                </span>
              </span>
              <span class="shrink-0 text-xs font-semibold text-warning">
                {if @two_factor == :pending, do: gettext("Continue"), else: gettext("Turn on")}
              </span>
            </.link>
          </section>

          <p
            :if={@query != "" and not any_shown?(assigns)}
            id="settings-search-empty"
            class="rounded-panel bg-base-100 p-6 text-sm text-muted lg:col-span-2"
          >
            {gettext("Nothing in Settings matches “%{query}”.", query: @query)}
          </p>
        </div>

        <div class="flex min-h-0 flex-col gap-5">
          <%!-- ── Preferences ─────────────────────────────────────────── --%>
          <section
            :if={@show.(:preferences, nil)}
            id="settings-preferences"
            aria-label={gettext("Preferences")}
            class="flex flex-col gap-[1.125rem] rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="font-display text-xl font-semibold">{gettext("Preferences")}</h2>
              <p class="text-[0.8125rem] text-muted">{gettext("Only for you, in this panel")}</p>
            </div>

            <div class="flex flex-col gap-2">
              <span id="settings-language-label" class="text-[0.8125rem] font-medium text-subtle">
                {gettext("Language")}
              </span>
              <nav
                id="settings-language"
                aria-labelledby="settings-language-label"
                class="grid auto-cols-fr grid-flow-col gap-1 rounded-full bg-secondary p-1"
              >
                <a
                  :for={locale <- locales()}
                  id={"settings-locale-#{locale}"}
                  href={~p"/locale/#{locale}?#{[return_to: ~p"/settings"]}"}
                  aria-current={locale == current_locale() && "true"}
                  class={[
                    "flex h-9 items-center justify-center rounded-full px-3 text-[0.8125rem] transition-colors",
                    if(locale == current_locale(),
                      do: "bg-inverse font-semibold text-on-inverse",
                      else: "text-subtle hover:text-base-content"
                    )
                  ]}
                >
                  {locale_label(locale)}
                </a>
              </nav>
            </div>

            <div class="flex flex-col gap-2">
              <span id="settings-theme-label" class="text-[0.8125rem] font-medium text-subtle">
                {gettext("Theme")}
              </span>
              <div
                id="settings-scheme"
                role="radiogroup"
                aria-labelledby="settings-theme-label"
                phx-hook=".SchemeCards"
                phx-update="ignore"
                class="grid grid-cols-3 gap-2"
              >
                <.scheme_card scheme="light" label={gettext("Light")} icon="hero-sun" />
                <.scheme_card scheme="dark" label={gettext("Dark")} icon="hero-moon" />
                <.scheme_card
                  scheme="system"
                  label={gettext("System")}
                  icon="hero-computer-desktop"
                />
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".SchemeCards">
                export default {
                  mounted() {
                    this.sync = () => {
                      const pref = window.PetalColorScheme ? window.PetalColorScheme.preference() : "system"
                      this.el.querySelectorAll("[data-scheme]").forEach((b) => {
                        b.setAttribute("aria-checked", b.dataset.scheme === pref ? "true" : "false")
                      })
                    }
                    this.el.addEventListener("click", (e) => {
                      const b = e.target.closest("[data-scheme]")
                      if (b && window.PetalColorScheme) window.PetalColorScheme.set(b.dataset.scheme)
                    })
                    window.addEventListener("petal:scheme-changed", this.sync)
                    this.sync()
                  },
                  destroyed() { window.removeEventListener("petal:scheme-changed", this.sync) }
                }
              </script>
            </div>

            <div class="flex flex-col gap-2">
              <span class="text-[0.8125rem] font-medium text-subtle">{gettext("Show times in")}</span>
              <div
                id="settings-timezone"
                class="flex h-[2.875rem] items-center justify-between gap-3 rounded-[0.875rem] border border-line-raised bg-secondary px-3.5 text-sm"
              >
                <span>{gettext("This browser's time zone")}</span>
                <span
                  id="settings-timezone-name"
                  phx-hook=".TimeZoneName"
                  phx-update="ignore"
                  class="truncate font-mono text-xs text-muted"
                ></span>
              </div>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".TimeZoneName">
                export default {
                  mounted() {
                    try { this.el.textContent = Intl.DateTimeFormat().resolvedOptions().timeZone || "" } catch (_e) {}
                  }
                }
              </script>
            </div>
          </section>

          <%!-- ── About ───────────────────────────────────────────────── --%>
          <section
            :if={@updates && @show.(:about, nil)}
            id="settings-about"
            aria-label={gettext("About")}
            class="flex flex-1 flex-col gap-3.5 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-center gap-3">
              <span class="logo-tile flex size-11 shrink-0 items-center justify-center rounded-[0.875rem]">
                <Layouts.logo_chevrons class="size-6" />
              </span>
              <div class="flex min-w-0 flex-col">
                <h2 class="font-display text-xl font-semibold">{gettext("About")}</h2>
                <p class="text-[0.8125rem] text-muted">
                  {gettext("Conditional Actions for Hell Let Loose")}
                </p>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-2">
              <div class="flex flex-col gap-1 rounded-2xl bg-secondary px-3.5 py-3">
                <span class="text-xs text-muted">{gettext("Installed version")}</span>
                <strong id="settings-version" class="truncate font-mono text-base font-medium">
                  {Updates.current_version()}
                </strong>
              </div>

              <div
                :if={@updates.latest}
                id="settings-latest"
                class={[
                  "flex flex-col gap-1 rounded-2xl px-3.5 py-3",
                  if(@updates.update_available?,
                    do: "border border-primary/30 bg-primary/8",
                    else: "bg-secondary"
                  )
                ]}
              >
                <span class={[
                  "flex items-center gap-1.5 text-xs",
                  if(@updates.update_available?, do: "text-primary", else: "text-muted")
                ]}>
                  <span
                    :if={@updates.update_available?}
                    class="size-2 rounded-full bg-primary shadow-[0_0_0_3px_color-mix(in_oklab,var(--color-primary)_20%,transparent)]"
                    aria-hidden="true"
                  ></span>
                  {if @updates.update_available?,
                    do: gettext("Update available"),
                    else: gettext("Latest release")}
                </span>
                <strong class="truncate font-mono text-base font-medium">
                  {@updates.latest.tag}
                </strong>
              </div>
            </div>

            <ul
              :if={note_items(@updates.latest) != []}
              id="settings-release-notes"
              class="flex flex-col gap-2 text-[0.8125rem] leading-[1.45] text-subtle"
            >
              <li :for={item <- note_items(@updates.latest)} class="flex gap-2">
                <span class="text-primary" aria-hidden="true">+</span><span class="line-clamp-2">{item}</span>
              </li>
            </ul>

            <p
              :if={@updates.latest && not @updates.update_available?}
              class="flex items-center gap-2 text-[0.8125rem] text-subtle"
            >
              <.icon name="hero-check-circle" class="size-4 text-primary" />
              {gettext("You are up to date.")}
            </p>

            <p :if={@updates.error} class="text-xs text-muted">
              {gettext("GitHub could not be reached, so this may be out of date.")}
            </p>

            <span class="flex-1"></span>

            <div class="flex gap-2">
              <%= if @updates.update_available? do %>
                <.link
                  id="settings-how-to-update"
                  href="https://github.com/fxsobr/hll_conditional_actions/wiki"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="flex h-12 flex-1 items-center justify-center rounded-full bg-[var(--tone-cta)] px-5 text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90"
                >
                  {gettext("See how to update")}
                </.link>
              <% else %>
                <button
                  id="settings-check-updates"
                  type="button"
                  phx-click="check_updates"
                  class="flex h-12 flex-1 items-center justify-center gap-2 rounded-full border border-base-300 bg-secondary px-5 text-sm transition-colors hover:bg-base-300"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> {gettext("Check now")}
                </button>
              <% end %>
              <.link
                :if={@updates.latest}
                id="settings-release-link"
                href={@updates.latest.url}
                target="_blank"
                rel="noopener noreferrer"
                class="flex h-12 items-center rounded-full border border-base-300 bg-secondary px-4 text-sm transition-colors hover:bg-base-300"
              >
                {gettext("Release notes")}
              </.link>
            </div>

            <p class="text-xs text-muted">
              {gettext("Talks to CRCON through its official API")}
              <span :if={@updates.checked_at}>
                · {gettext("checked at")}
                <.clock
                  id="settings-checked-at"
                  at={@updates.checked_at}
                  class="font-mono"
                />
              </span>
            </p>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp any_shown?(assigns) do
    %{query: query, servers: servers, current_user: user} = assigns
    keys = [:users, :roles, :discord, :payments, :metrics, :modules, :preferences, :about]

    shown?(query, terms(:servers, servers)) or shown?(query, terms(:account, user)) or
      Enum.any?(keys, &shown?(query, terms(&1, nil)))
  end

  attr :server, :map, required: true
  attr :status, :any, default: nil
  attr :live, :any, default: nil

  # "Carentan · Guerra · 98/100" from the live state; a server whose stream
  # is down still answers REST, but its event rules are blind.
  defp tile_line(assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-xs text-white/80">
      <span class={["size-2 shrink-0 rounded-full", stream_dot(@status, @server.enabled)]}></span>
      <span class="truncate">
        <%= cond do %>
          <% not @server.enabled -> %>
            {gettext("Disabled")}
          <% is_map(@live) and match?({:error, _}, @status) -> %>
            {Enum.join(
              Enum.reject(
                [
                  @live.map,
                  @live.mode && LiveComponents.mode_label(@live.mode),
                  gettext("rules blind")
                ],
                &is_nil/1
              ),
              " · "
            )}
          <% is_map(@live) -> %>
            {Enum.join(
              Enum.reject(
                [@live.map, @live.mode && LiveComponents.mode_label(@live.mode)],
                &is_nil/1
              ),
              " · "
            )} · <span class="font-mono">{@live.players}/{@live.max_players || "–"}</span>
          <% match?({:error, _}, @status) -> %>
            {gettext("Stream down")} · {gettext("rules blind")}
          <% true -> %>
            {Labels.stream_status(@status)} · {game_short(@server.game)}
        <% end %>
      </span>
    </span>
    """
  end

  attr :engine, :map, default: nil
  attr :streams, :any, required: true

  defp engine_line(assigns) do
    {up, total} = assigns.streams
    engine = assigns.engine || %{}

    assigns =
      assigns
      |> assign(:queue, engine[:queue])
      |> assign(:p95, engine[:p95_ms])
      |> assign(:up, up)
      |> assign(:total, total)

    ~H"""
    <span :if={is_integer(@queue)}>{gettext("queue %{count}", count: @queue)} · </span><span
      :if={is_number(@p95)}
      class="font-mono"
    >p95 {format_ms(@p95)} ms</span><span :if={is_number(@p95)}> · </span>{gettext(
      "%{up} of %{total} streams",
      up: @up,
      total: @total
    )}
    """
  end

  defp format_ms(ms) when is_float(ms), do: ms |> round() |> Integer.to_string()
  defp format_ms(ms), do: to_string(ms)

  attr :scheme, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp scheme_card(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      aria-checked="false"
      id={"settings-scheme-#{@scheme}"}
      data-scheme={@scheme}
      class="settings-scheme-card flex flex-col gap-2 rounded-2xl border border-line-raised bg-secondary p-2 text-left transition-colors hover:border-line-strong"
    >
      <span
        class={["settings-scheme-preview", "settings-scheme-preview--#{@scheme}"]}
        aria-hidden="true"
      >
        <span :if={@scheme != "system"}></span>
        <span :if={@scheme != "system"}></span>
        <span :if={@scheme != "system"}></span>
      </span>
      <span class="flex items-center gap-1.5 px-0.5 pb-0.5 text-[0.8125rem]">
        <.icon name={@icon} class="size-3.5" /> {@label}
      </span>
    </button>
    """
  end
end
