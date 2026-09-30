defmodule HllConditionalActionsWeb.MoreSheet do
  @moduledoc """
  "Mais", the last tab of the phone and tablet tab bar: the account, the
  areas the bar has no room for, the VIP shop's day, the server in scope,
  the theme of this device and signing out.

  A full screen `<dialog>` over the page, with its own copy of the tab bar
  so "Mais" reads as the tab you are on. The shop line is read when the
  sheet opens, not on every page.
  """

  use HllConditionalActionsWeb, :live_component

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.ShopSummary
  alias HllConditionalActions.Updates
  alias HllConditionalActions.VipShop
  alias HllConditionalActionsWeb.Layouts
  alias HllConditionalActionsWeb.Nav

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, assign(socket, :shop, nil)}

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     assign(socket, Map.take(assigns, [:id, :current_user, :current_path, :nav, :areas, :active]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("open", _params, socket) do
    shop =
      if shop?(socket.assigns.current_user, socket.assigns.nav),
        do: ShopSummary.today(),
        else: nil

    {:noreply, assign(socket, :shop, shop)}
  end

  defp shop?(user, nav),
    do: Accounts.can?(user, :manage_integrations) and Nav.feature?(nav, :vip_shop)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    by_key = Map.new(assigns.areas, &{&1.key, &1})
    user = assigns.current_user

    assigns =
      assign(assigns,
        others:
          for(key <- [:community, :players, :modules, :settings], by_key[key], do: by_key[key]),
        two_factor?: not is_nil(Map.get(user, :totp_confirmed_at)),
        server_count: length((assigns.nav && assigns.nav[:servers]) || []),
        shop_link?: shop?(user, assigns.nav)
      )

    ~H"""
    <div id={@id}>
      <dialog
        id="more-sheet-dialog"
        class="more-sheet"
        aria-labelledby="more-sheet-title"
        x-data
        x-on:click="if ($event.target.closest('a')) $el.close()"
      >
        <div class="mx-auto flex max-w-xl flex-col gap-3 px-4 pb-32 pt-4">
          <header class="flex h-13 items-center gap-2.5">
            <h1
              id="more-sheet-title"
              class="flex-1 font-display text-[1.75rem] font-semibold tracking-[-0.02em]"
            >
              {gettext("More")}
            </h1>
            <.link
              navigate={~p"/inbox"}
              class="icon-round relative size-11"
              aria-label={gettext("Inbox")}
            >
              <.icon name="hero-bell" class="size-5" />
              <span
                :if={((@nav && @nav[:unread]) || 0) > 0}
                class="bell-dot"
                aria-hidden="true"
              ></span>
            </.link>
          </header>

          <.link
            navigate={~p"/account"}
            class="more-card flex min-h-[4.75rem] items-center gap-3.5 py-3 pl-3 pr-4"
          >
            <span class="avatar-button size-13 text-base">{Layouts.initials(@current_user)}</span>
            <span class="flex min-w-0 flex-1 flex-col gap-[3px]">
              <strong class="truncate text-base font-semibold">
                {@current_user.name || @current_user.username}
              </strong>
              <span class="flex flex-wrap items-center gap-1.5 text-xs text-muted">
                {[
                  Layouts.role_name(@current_user),
                  ngettext("1 server", "%{count} servers", @server_count)
                ]
                |> Enum.reject(&is_nil/1)
                |> Enum.join(" · ")}
                <span
                  :if={@two_factor?}
                  class="rounded-full bg-primary/12 px-[7px] py-0.5 text-[0.6875rem] font-semibold text-primary"
                >
                  {gettext("2FA on")}
                </span>
              </span>
            </span>
            <.icon name="hero-chevron-right" class="size-4 text-muted" />
          </.link>

          <nav
            :if={@others != []}
            aria-label={gettext("Other areas")}
            class="more-card py-1.5 pl-3 pr-4"
          >
            <.link :for={area <- @others} navigate={area.path} class="more-row">
              <span class="more-tile"><.icon name={area.icon} class="size-[1.1875rem]" /></span>
              <span class="flex min-w-0 flex-1 flex-col gap-px">
                <strong class="text-[0.9375rem] font-semibold">{area.label}</strong>
                <span class="truncate text-xs text-muted">{area_hint(area.key)}</span>
              </span>
              <.icon name="hero-chevron-right" class="size-4 text-muted" />
            </.link>
          </nav>

          <nav
            :if={@shop_link? or @server_count > 1}
            aria-label={gettext("Shortcuts")}
            class="more-card py-1.5 pl-3 pr-4"
          >
            <.link :if={@shop_link?} navigate={~p"/vip-shop/purchases"} class="more-row">
              <span class="more-tile bg-primary/12 text-primary">
                <.icon name="hero-shopping-bag" class="size-[1.1875rem]" />
              </span>
              <span class="flex min-w-0 flex-1 flex-col gap-px">
                <strong class="text-[0.9375rem] font-semibold">{gettext("VIP shop purchases")}</strong>
                <span :if={@shop} class="truncate text-xs text-muted">{shop_line(@shop)}</span>
              </span>
              <span
                :if={@shop && @shop.pending > 0}
                class="rounded-full bg-warning/13 px-2.5 py-1 text-[0.6875rem] font-bold text-warning"
              >
                {ngettext("1 pending", "%{count} pending", @shop.pending)}
              </span>
              <.icon
                :if={!(@shop && @shop.pending > 0)}
                name="hero-chevron-right"
                class="size-4 text-muted"
              />
            </.link>

            <details :if={@server_count > 1} class="more-row-details group">
              <summary class="more-row cursor-pointer list-none">
                <span class="more-tile"><.icon name="hero-server-stack" class="size-[1.1875rem]" /></span>
                <span class="flex min-w-0 flex-1 flex-col gap-px">
                  <strong class="text-[0.9375rem] font-semibold">{gettext("Server in scope")}</strong>
                  <span class="truncate text-xs text-muted">
                    {if @nav.server, do: @nav.server.name, else: gettext("All servers")}
                  </span>
                </span>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-muted transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="pb-2">
                <Layouts.scope_options
                  nav={@nav}
                  current_user={@current_user}
                  current_path={@current_path}
                />
              </div>
            </details>
          </nav>

          <section aria-labelledby="more-theme" class="more-card flex flex-col gap-2.5 px-4 py-3.5">
            <div class="flex items-baseline">
              <h2 id="more-theme" class="flex-1 text-sm font-semibold">{gettext("Theme")}</h2>
              <span class="text-xs text-muted">{gettext("applies to this device")}</span>
            </div>
            <Layouts.scheme_choice id="more-scheme" size="lg" />
          </section>

          <.link
            href={~p"/logout"}
            method="delete"
            id="more-sheet-logout"
            class="flex h-12 items-center justify-center gap-2 rounded-full border border-base-300 bg-base-100 text-sm font-semibold text-error"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-[1.0625rem]" />
            {gettext("Sign out")}
          </.link>

          <p class="text-center text-xs text-muted">
            {gettext("Conditional Actions")} ·
            <span class="font-mono">{Updates.current_version()}</span>
          </p>
        </div>

        <Layouts.tab_bar
          id="more-tab-bar"
          areas={@areas}
          active={@active}
          nav={@nav}
          more_active
          in_sheet
        />
      </dialog>
    </div>
    """
  end

  defp area_hint(:community), do: gettext("Seasons, achievements and the VIP shop")
  defp area_hint(:players), do: gettext("Search, watchlist and history")
  defp area_hint(:modules), do: gettext("Turn features on for each server")
  defp area_hint(:settings), do: gettext("Servers, users and integrations")
  defp area_hint(_key), do: nil

  defp shop_line(%{paid: paid, revenue: revenue}) do
    money =
      Enum.map_join(revenue, " + ", fn {currency, cents} ->
        VipShop.format_money(cents || 0, currency)
      end)

    [ngettext("1 paid today", "%{count} paid today", paid), money != "" && money]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end
end
