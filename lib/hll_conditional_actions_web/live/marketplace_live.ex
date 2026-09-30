defmodule HllConditionalActionsWeb.MarketplaceLive do
  @moduledoc """
  A server's marketplace (Marketplace board): every optional module, what it
  adds, what it holds on this server, and a button to install or remove it;
  beside them how many modules the server runs, the other servers, and a
  way to copy another server's modules onto this one.

  Removing a module hides its pages and stops its background work, but keeps
  its data - installing it again brings everything back as it was.

  Two figures come from CRCON and are read after the page is up, never on a
  render: how many matches its history keeps (cached for ten minutes by
  `Features.Usage`) and whether the key can read what the VIP shop needs
  (stored on the server, re-read after six hours by `Features.ShopKey`).
  Both are reads; nothing changes on the game server.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_servers}}

  import HllConditionalActionsWeb.BriefingComponents, only: [format_number: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Features
  alias HllConditionalActions.Features.Copy
  alias HllConditionalActions.Features.ShopKey
  alias HllConditionalActions.Features.Usage
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.Labels

  # The order of the board: what runs the server first, community last.
  @order [:rules, :tickets, :stats, :live_feed, :progression, :vip_shop]

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id}, _session, socket) do
    server = Servers.get_server!(server_id)

    if Accounts.can_access_server?(socket.assigns.current_user, server) do
      socket =
        socket
        |> assign(:server, server)
        |> assign(:page_title, gettext("Modules"))
        |> assign(:installed, Features.installed(server.id))
        |> assign(:usage, Usage.for_server(server))
        |> assign(:matches, :loading)
        |> assign(:missing_shop, ShopKey.missing(server))
        |> assign(:others, other_servers(socket.assigns.current_user, server))
        |> assign(:copy, nil)

      socket =
        if connected?(socket) do
          socket
          |> load_matches()
          |> check_shop_key()
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/servers")}
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("install", %{"feature" => name}, socket) do
    with feature when not is_nil(feature) <- Features.parse(name),
         :ok <- Features.install(socket.assigns.server.id, feature, actor(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("%{module} installed.", module: Labels.feature(feature)))
       |> refresh()}
    else
      _error -> {:noreply, put_flash(socket, :error, gettext("Could not install the module."))}
    end
  end

  def handle_event("uninstall", %{"feature" => name}, socket) do
    case Features.parse(name) do
      nil ->
        {:noreply, socket}

      feature ->
        :ok = Features.uninstall(socket.assigns.server.id, feature)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{module} removed. Its data is kept for when you install it again.",
             module: Labels.feature(feature)
           )
         )
         |> refresh()}
    end
  end

  def handle_event("copy_open", _params, socket) do
    {:noreply, assign(socket, :copy, %{source: nil, plan: nil, remove_extras: false})}
  end

  def handle_event("copy_close", _params, socket) do
    {:noreply, assign(socket, :copy, nil)}
  end

  def handle_event("copy_source", %{"id" => id}, socket) do
    case {socket.assigns.copy, find_other(socket, id)} do
      {%{} = copy, %{} = other} ->
        plan = Copy.plan(other.server.id, socket.assigns.server.id)
        {:noreply, assign(socket, :copy, %{copy | source: other.server, plan: plan})}

      _no_dialog_or_unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_toggle_extras", _params, socket) do
    case socket.assigns.copy do
      %{} = copy ->
        {:noreply, assign(socket, :copy, %{copy | remove_extras: not copy.remove_extras})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("copy_apply", _params, socket) do
    with %{source: %{} = source, remove_extras: remove_extras} <- socket.assigns.copy,
         %{} <- find_other(socket, source.id),
         {:ok, changes} <-
           Copy.copy(source.id, socket.assigns.server.id,
             remove_extras: remove_extras,
             actor: actor(socket)
           ) do
      message =
        if changes.installed == [] and changes.removed == [] do
          gettext("Nothing to change: this server already runs what %{server} runs.",
            server: source.name
          )
        else
          gettext("Modules copied from %{server}.", server: source.name)
        end

      {:noreply,
       socket
       |> assign(:copy, nil)
       |> put_flash(:info, message)
       |> refresh()}
    else
      _no_source ->
        {:noreply, put_flash(socket, :error, gettext("Pick the server to copy from."))}
    end
  end

  # ── CRCON reads, after the page is up ─────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_async(:matches, {:ok, result}, socket) do
    {:noreply, assign(socket, :matches, result)}
  end

  def handle_async(:matches, {:exit, reason}, socket) do
    {:noreply, assign(socket, :matches, {:error, reason})}
  end

  def handle_async(:shop_key, {:ok, {:ok, server}}, socket) do
    {:noreply, assign(socket, :missing_shop, ShopKey.missing(server))}
  end

  def handle_async(:shop_key, _unknown, socket), do: {:noreply, socket}

  # Only for a server that shows its matches: the count sits on that card.
  defp load_matches(socket) do
    server = socket.assigns.server

    if MapSet.member?(socket.assigns.installed, :stats) do
      start_async(socket, :matches, fn -> Usage.saved_matches(server) end)
    else
      socket
    end
  end

  defp check_shop_key(socket) do
    server = socket.assigns.server

    if ShopKey.stale?(server) do
      start_async(socket, :shop_key, fn -> ShopKey.refresh(server) end)
    else
      socket
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # The sidebar reads the same installations, so it is refreshed alongside
  # the cards; otherwise a new module would only show up after navigating.
  defp refresh(socket) do
    server = socket.assigns.server
    installed = Features.installed(server.id)
    stats_added? = :stats in installed and :stats not in socket.assigns.installed

    nav =
      case socket.assigns[:nav] do
        %{features: features} = nav -> %{nav | features: Map.put(features, server.id, installed)}
        nav -> nav
      end

    socket =
      socket
      |> assign(:installed, installed)
      |> assign(:usage, Usage.for_server(server))
      |> assign(:nav, nav)

    if stats_added? and connected?(socket), do: load_matches(socket), else: socket
  end

  defp actor(socket), do: socket.assigns.current_user.email

  defp find_other(socket, id) do
    Enum.find(socket.assigns.others, &(to_string(&1.server.id) == to_string(id)))
  end

  # The other servers this user may see, with how many modules each runs, so
  # the page answers "is this server set up like the rest?".
  defp other_servers(user, server) do
    servers = user |> Servers.list_servers_for() |> Enum.reject(&(&1.id == server.id))
    installed = Features.installed_by_server(Enum.map(servers, & &1.id))

    Enum.map(
      servers,
      &%{server: &1, count: installed |> Map.get(&1.id, MapSet.new()) |> MapSet.size()}
    )
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:catalog, Enum.filter(@order, &(&1 in Features.catalog())))
      |> assign(:total, length(Features.catalog()))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Modules")}
      page_subtitle={gettext("New servers start empty. Install only what your community uses.")}
      global_search={false}
      bell={false}
    >
      <div class="grid gap-5 xl:min-h-[calc(100dvh-8.75rem)] xl:grid-cols-[minmax(0,1fr)_22.5rem]">
        <div
          id="marketplace"
          class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3 xl:grid-rows-2"
        >
          <.module_card
            :for={feature <- @catalog}
            feature={feature}
            installed={MapSet.member?(@installed, feature)}
            usage={@usage}
            matches={@matches}
            missing_shop={@missing_shop}
          />
        </div>

        <div class="grid content-start gap-5 md:grid-cols-2 xl:flex xl:flex-col">
          <section
            id="marketplace-summary"
            aria-label={gettext("On this server")}
            class="mkt-panel flex flex-col gap-3.5 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <h2 class="font-display text-xl font-semibold">{gettext("On this server")}</h2>
            <div class="flex items-baseline gap-2">
              <span
                id="marketplace-count"
                class="font-display text-5xl font-bold leading-none tabular-nums"
              >
                {MapSet.size(@installed)}
              </span>
              <span class="text-[0.9375rem] text-subtle">
                {gettext("of %{count} modules", count: @total)}
              </span>
            </div>
            <div
              class="grid gap-1"
              style={"grid-template-columns: repeat(#{@total}, minmax(0, 1fr))"}
              aria-hidden="true"
            >
              <span
                :for={index <- 1..@total//1}
                class={[
                  "h-2 rounded",
                  if(index <= MapSet.size(@installed), do: "bg-primary", else: "bg-base-300")
                ]}
              ></span>
            </div>
            <p class="text-[0.8125rem] leading-normal text-subtle">
              {gettext(
                "Removing a module hides its pages but keeps its data. Installing it again brings everything back."
              )}
            </p>
          </section>

          <section
            :if={@others != []}
            id="marketplace-others"
            aria-label={gettext("The other servers")}
            class="mkt-panel flex flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem] xl:flex-1"
          >
            <h2 class="font-display text-xl font-semibold">{gettext("The other servers")}</h2>
            <.link
              :for={other <- @others}
              id={"other-server-#{other.server.id}"}
              navigate={~p"/servers/#{other.server}/marketplace"}
              class="flex items-center gap-3 rounded-2xl bg-secondary px-3 py-2.5 transition-colors hover:bg-base-300/60"
            >
              <img
                src={server_art(other.server)}
                alt=""
                class="size-10 shrink-0 rounded-xl object-cover"
              />
              <span class="flex min-w-0 flex-1 flex-col">
                <strong class="truncate text-sm font-semibold">{other.server.name}</strong>
                <span class="text-xs text-muted">
                  {gettext("%{count} of %{total} modules", count: other.count, total: @total)}
                </span>
              </span>
            </.link>
            <span class="flex-1"></span>
            <button
              type="button"
              id="copy-modules"
              phx-click="copy_open"
              class="chip-button h-11 w-full justify-center bg-overlay text-sm dark:bg-secondary"
            >
              {gettext("Copy modules from another server")}
            </button>
          </section>
        </div>
      </div>

      <.copy_dialog :if={@copy} copy={@copy} server={@server} others={@others} />
    </Layouts.app>
    """
  end

  # ── Module card ───────────────────────────────────────────────────────────

  attr :feature, :atom, required: true
  attr :installed, :boolean, required: true
  attr :usage, :map, required: true
  attr :matches, :any, required: true
  attr :missing_shop, :list, required: true

  defp module_card(assigns) do
    ~H"""
    <article
      id={"feature-#{@feature}"}
      class={[
        "mkt-card flex min-w-0 flex-col gap-3 rounded-panel bg-base-100 p-6",
        not @installed && "mkt-card--available"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <span class={["mkt-tile", "mkt-tile--#{@feature}"]}>
          <.module_icon feature={@feature} />
        </span>
        <span
          :if={@installed}
          class="flex items-center gap-1.5 text-xs font-semibold text-primary"
        >
          <svg
            class="size-3.5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="3"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="m5 12.5 4.5 4.5L19 7.5" />
          </svg>
          {gettext("Installed")}
        </span>
        <span :if={not @installed} class="text-xs text-muted">{gettext("Available")}</span>
      </div>

      <h2 class="font-display text-[1.375rem] font-semibold leading-[1.2]">
        {Labels.feature(@feature)}
      </h2>
      <p class="text-sm leading-normal text-subtle">
        <.description feature={@feature} />
      </p>

      <div :if={tags(@feature, @usage) != []} class="flex flex-wrap gap-1.5">
        <span
          :for={tag <- tags(@feature, @usage)}
          class="rounded-full bg-secondary px-2.5 py-1 text-xs text-subtle"
        >
          {tag}
        </span>
      </div>

      <div
        :if={@feature == :vip_shop and @missing_shop != []}
        id="vip-shop-permissions"
        class="mkt-warn flex items-start gap-2 rounded-[0.875rem] px-3 py-2.5"
      >
        <svg
          class="mkt-warn-icon mt-px size-4 shrink-0"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M12 4 2.5 20h19L12 4z" /><path d="M12 10v4.5M12 17.5h.01" />
        </svg>
        <span class="flex flex-col gap-1 text-xs leading-[1.45]">
          <span :for={permission <- @missing_shop}>
            <.with_code text={shop_warning(permission)} code={permission} placeholder="permission" />
          </span>
        </span>
      </div>

      <span class="flex-1"></span>

      <%= if @installed do %>
        <div class="flex items-center justify-between gap-3">
          <span id={"usage-#{@feature}"} class="text-xs text-muted">
            {usage_line(@feature, @usage, @matches)}
          </span>
          <button
            type="button"
            id={"uninstall-#{@feature}"}
            phx-click="uninstall"
            phx-value-feature={@feature}
            data-confirm={gettext("Remove this module from the server?")}
            class="inline-flex h-10 shrink-0 cursor-pointer items-center rounded-full border border-base-300 px-4 text-[0.8125rem] text-subtle transition-colors hover:border-line-strong hover:text-base-content"
          >
            {gettext("Remove")}
          </button>
        </div>
      <% else %>
        <button
          type="button"
          id={"install-#{@feature}"}
          phx-click="install"
          phx-value-feature={@feature}
          class="chip-button chip-button--signal h-11 w-full justify-center text-sm"
        >
          {gettext("Install on this server")}
        </button>
      <% end %>
    </article>
    """
  end

  attr :feature, :atom, required: true

  defp description(%{feature: :tickets} = assigns) do
    ~H"""
    <.with_code
      text={
        gettext(
          "Players call the staff from the chat with %{command}, and the conversation becomes a ticket in the Inbox.",
          command: "%{command}"
        )
      }
      code="!admin"
      placeholder="command"
      class="text-[0.8125rem]"
    />
    """
  end

  defp description(assigns) do
    ~H"""
    {description_text(@feature)}
    """
  end

  defp description_text(:rules),
    do:
      gettext(
        "When something happens in the game and the situation matches, the server acts on its own."
      )

  defp description_text(:stats),
    do: gettext("Live scoreboard, best squads and a report of every match.")

  defp description_text(:live_feed),
    do:
      gettext(
        "Every kill, connection and chat message, with the rules that acted marked on the line."
      )

  defp description_text(:progression),
    do: gettext("Medals for performance and season-long contests, with VIP as a prize.")

  defp description_text(:vip_shop),
    do: gettext("Sell VIP packages with Pix or card. Delivery on the server is automatic.")

  attr :text, :string, required: true
  attr :code, :string, required: true
  attr :placeholder, :string, required: true
  attr :class, :any, default: nil

  # A translated sentence with a command or permission name set in mono
  # where its placeholder sits, so translators keep the whole sentence.
  defp with_code(assigns) do
    assigns =
      assign(
        assigns,
        :parts,
        String.split(assigns.text, "%{#{assigns.placeholder}}", parts: 2)
      )

    ~H"""
    <%= case @parts do %>
      <% [before, rest] -> %>
        {before}<span class={["font-mono", @class]}>{@code}</span>{rest}
      <% [whole] -> %>
        {whole}
    <% end %>
    """
  end

  defp tags(:rules, _usage) do
    recipes = Usage.recipes()

    [
      gettext("Rules"),
      gettext("History"),
      ngettext("%{count} recipe", "%{count} recipes", recipes)
    ]
  end

  defp tags(:tickets, _usage), do: [gettext("Inbox"), gettext("Office hours")]
  defp tags(:stats, _usage), do: [gettext("Scoreboard"), gettext("Matches")]

  defp tags(:progression, _usage) do
    count = Usage.starter_achievements()
    [ngettext("Comes with %{count} achievement", "Comes with %{count} achievements", count)]
  end

  defp tags(_feature, _usage), do: []

  defp usage_line(:rules, usage, _matches),
    do: ngettext("%{count} rule on this server", "%{count} rules on this server", usage.rules)

  defp usage_line(:tickets, usage, _matches),
    do: ngettext("%{count} open now", "%{count} open now", usage.tickets)

  defp usage_line(:stats, _usage, :loading), do: gettext("Counting matches…")

  defp usage_line(:stats, _usage, {:ok, total}),
    do:
      ngettext("%{number} saved match", "%{number} saved matches", total,
        number: format_number(total)
      )

  defp usage_line(:stats, _usage, _error), do: gettext("Match history unavailable")

  defp usage_line(:live_feed, usage, _matches),
    do: gettext("Keeps the last %{count} lines", count: usage.live_feed)

  defp usage_line(:progression, usage, _matches),
    do:
      ngettext(
        "%{count} achievement on this server",
        "%{count} achievements on this server",
        usage.progression
      )

  defp usage_line(:vip_shop, usage, _matches),
    do: ngettext("%{count} package on sale", "%{count} packages on sale", usage.vip_shop)

  defp shop_warning("can_view_vip_ids"),
    do:
      gettext("The CRCON key needs to read the VIP list (%{permission}).",
        permission: "%{permission}"
      )

  defp shop_warning("can_add_vip"),
    do:
      gettext("The CRCON key needs to grant VIP (%{permission}).",
        permission: "%{permission}"
      )

  defp shop_warning("can_view_player_history"),
    do:
      gettext("The CRCON key needs to read the player history (%{permission}).",
        permission: "%{permission}"
      )

  defp shop_warning(_permission),
    do:
      gettext("The CRCON key is missing a permission the shop needs (%{permission}).",
        permission: "%{permission}"
      )

  attr :feature, :atom, required: true

  # The board's glyphs, drawn at 26px on the solid tile.
  defp module_icon(assigns) do
    ~H"""
    <svg
      class="size-[1.625rem]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <%= case @feature do %>
        <% :rules -> %>
          <path d="M13 3 5 13.5h6L10 21l8-10.5h-6L13 3z" />
        <% :tickets -> %>
          <path d="M4 5h16v11H9l-5 4V5z" />
        <% :stats -> %>
          <path d="M5 20V10M12 20V4M19 20v-7" />
        <% :live_feed -> %>
          <circle cx="12" cy="12" r="2" />
          <path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8" />
        <% :progression -> %>
          <path d="M8 4h8v5a4 4 0 0 1-8 0V4z" />
          <path d="M8 6H5a3 3 0 0 0 3 4M16 6h3a3 3 0 0 1-3 4M12 13v4M8.5 20h7" />
        <% :vip_shop -> %>
          <path d="M3 9h18v11H3zM12 9v11M3 9l3-5h12l3 5" />
        <% _other -> %>
          <circle cx="12" cy="12" r="8" />
      <% end %>
    </svg>
    """
  end

  # ── Copy dialog ───────────────────────────────────────────────────────────

  attr :copy, :map, required: true
  attr :server, :map, required: true
  attr :others, :list, required: true

  # Pick a server, see what changes, confirm. Missing modules are installed;
  # the ones only this server runs stay unless the box is ticked.
  defp copy_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="copy-dialog"
      tone="primary"
      icon="hero-square-2-stack"
      title={gettext("Copy modules from another server")}
      subtitle={
        gettext(
          "%{server} will run the same modules as the server you pick. Only modules are copied, never rules or other data.",
          server: @server.name
        )
      }
      on_cancel={JS.push("copy_close")}
    >
      <div id="copy-sources" class="flex max-h-72 flex-col gap-2 overflow-y-auto">
        <button
          :for={other <- @others}
          type="button"
          id={"copy-source-#{other.server.id}"}
          phx-click="copy_source"
          phx-value-id={other.server.id}
          aria-pressed={to_string(@copy.source && @copy.source.id == other.server.id)}
          class={[
            "flex w-full cursor-pointer items-center gap-3 rounded-2xl border px-3 py-2.5 text-left transition-colors",
            if(@copy.source && @copy.source.id == other.server.id,
              do: "border-primary bg-primary/12",
              else: "border-transparent bg-secondary hover:border-line-strong"
            )
          ]}
        >
          <img src={server_art(other.server)} alt="" class="size-10 shrink-0 rounded-xl object-cover" />
          <span class="flex min-w-0 flex-1 flex-col">
            <strong class="truncate text-sm font-semibold">{other.server.name}</strong>
            <span class="text-xs text-muted">
              {gettext("%{count} of %{total} modules",
                count: other.count,
                total: length(Features.catalog())
              )}
            </span>
          </span>
          <.icon
            :if={@copy.source && @copy.source.id == other.server.id}
            name="hero-check-circle"
            class="size-5 shrink-0 text-primary"
          />
        </button>
      </div>

      <div
        :if={@copy.plan}
        id="copy-plan"
        class="flex flex-col gap-2 rounded-2xl bg-secondary px-4 py-3 text-[0.8125rem]"
      >
        <p :if={@copy.plan.install != []} id="copy-plan-install">
          {gettext("Installs: %{modules}", modules: module_list(@copy.plan.install))}
        </p>
        <p :if={@copy.plan.install == []} class="text-subtle">
          {gettext("Nothing to install: this server already runs every module %{server} runs.",
            server: @copy.source.name
          )}
        </p>
        <label
          :if={@copy.plan.extra != []}
          class="flex cursor-pointer items-start gap-2 text-subtle"
        >
          <input
            type="checkbox"
            id="copy-remove-extras"
            checked={@copy.remove_extras}
            phx-click="copy_toggle_extras"
            class="mt-0.5 size-4 shrink-0 accent-[var(--color-primary)]"
          />
          <span>
            {gettext("Also remove what %{server} does not run: %{modules}",
              server: @copy.source.name,
              modules: module_list(@copy.plan.extra)
            )}
          </span>
        </label>
      </div>

      <:note>{gettext("Removing a module keeps its data.")}</:note>
      <:confirm>
        <button
          type="button"
          id="copy-confirm"
          phx-click="copy_apply"
          disabled={is_nil(@copy.source)}
          class="chip-button chip-button--signal h-12 px-5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {gettext("Copy modules")}
        </button>
      </:confirm>
    </.confirm_dialog>
    """
  end

  defp module_list(features), do: Enum.map_join(features, ", ", &Labels.feature/1)
end
