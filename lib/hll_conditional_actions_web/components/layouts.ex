defmodule HllConditionalActionsWeb.Layouts do
  @moduledoc """
  Application layouts and the chrome around every page.

  `app/1` wraps authenticated pages in the "Posto de Comando" shell: the icon
  rail on wide screens (one entry per area, Ajustes and the account at the
  bottom), a header with the page title, the global search (Ctrl K), the
  server scope, the notifications bell and the page's own actions, and on
  tablets and phones a floating tab bar with a "Mais" sheet for the rest.

  The pages of an area show as pill tabs beside the title. The command
  palette (`HllConditionalActionsWeb.CommandPalette`), the notifications
  panel (`HllConditionalActionsWeb.NotificationsPanel`) and the "Mais" sheet
  (`HllConditionalActionsWeb.MoreSheet`) are live components, so typing a
  search or opening the bell re-renders only them, never the page.

  `auth/1` wraps the pages an anonymous visitor can reach. It is a split
  screen: Hell Let Loose key art on one side, the form on the other, so the
  tool looks like it belongs to the game it administers.
  """
  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Updates
  alias HllConditionalActionsWeb.Nav
  alias HllConditionalActionsWeb.Plugs.Locale
  alias HllConditionalActionsWeb.ReleaseNotes

  embed_templates "layouts/*"

  @doc """
  The shell for authenticated pages.

  Only `flash` is required; everything else refines the header:

    * `page_title`, with `crumb` above it ("Ajustes / Pessoas") - or
      `eyebrow`, the same line when it is not a path ("Briefing de um
      servidor novo") - `badges` beside it and `page_subtitle` under it;
      `page_meta` sits inline after the title instead ("4.812 conhecidos ·
      221 jogando agora").
    * `greeting` and `greeting_eyebrow`: on phones and tablets the header
      shows these instead of the title, beside the logo ("Terça, 29 de
      setembro" over "Boa noite, Marcelo"); wide screens keep `page_title`.
    * `back` puts a round back button before the title (detail pages); the
      area's tabs are not shown on those.
    * `tabs`: `:auto` (the default) shows the pages of the area as pill tabs
      beside the title, when the page is one of them; `false` hides them; a
      list of `%{label: .., path: .., count: .., active: .., patch: ..}`
      shows those instead (a page's own filters).
    * the header's right side: the global search field (`global_search={false}`
      hides it, the `:search` slot replaces it with the page's own), the
      server scope (`scope={false}`), the bell (`bell={false}`) and the
      `:actions` slot, last.
    * `tab_bar={false}` hides the phone/tablet tab bar, for a page with its
      own bottom action bar.
    * `inline_tabs`: on a tablet the tabs stay beside the title, the bell
      goes and the scope says "Servidores" (TabletInbox board) - for a page
      whose header has the room.
    * `phone_scope`: on a phone the header is the logo, the server scope and
      the bell, without the title, the search or the page's buttons (the
      cockpit, Mobile board).

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user} current_path={~p"/servers"}>
        <h1>Servers</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the signed in user"
  attr :current_path, :string, default: "/", doc: "used to highlight the active nav entry"

  attr :nav, :map,
    default: nil,
    doc: "the servers to switch between and the one in scope, from `HllConditionalActionsWeb.Nav`"

  attr :page_title, :string, default: nil
  attr :page_subtitle, :string, default: nil, doc: "one line of context under the page title"
  attr :page_meta, :string, default: nil, doc: "one line of context inline after the title"
  attr :crumb, :string, default: nil, doc: "where the page sits, above the title"
  attr :eyebrow, :string, default: nil, doc: "a line above the title, when it is not a crumb"

  attr :greeting, :string,
    default: nil,
    doc: "phones and tablets: the header's title in place of `page_title`"

  attr :greeting_eyebrow, :string,
    default: nil,
    doc: "phones and tablets: the line above `greeting`, e.g. the date"

  attr :back, :string,
    default: nil,
    doc: "shows a back arrow to the left of the title, for detail screens"

  attr :back_label, :string, default: nil

  attr :badges, :list,
    default: [],
    doc: "status pills beside the title: maps of %{id, label, tone, icon}"

  attr :tabs, :any, default: :auto, doc: ":auto, false, or a list of tab maps"
  attr :global_search, :boolean, default: true, doc: "the global search field in the header"
  attr :scope, :boolean, default: true, doc: "the server scope pill in the header"
  attr :bell, :boolean, default: true, doc: "the notifications bell in the header"

  attr :scope_tag, :string, default: nil, doc: "a word after the scoped server's name"

  attr :scope_nav, :map,
    default: nil,
    doc: "what the scope pill shows, when the page is about another server than `nav`'s"

  attr :inline_tabs, :boolean,
    default: false,
    doc: "tablets: the tabs beside the title instead of a row under the header"

  attr :phone_scope, :boolean,
    default: false,
    doc: "phones: the server scope in place of the title, search and buttons"

  attr :tab_bar, :boolean, default: true, doc: "the phone and tablet tab bar"

  attr :header, :boolean,
    default: true,
    doc: "the page header; off for pages whose content carries its own (the player 360)"

  slot :actions, doc: "buttons rendered on the right of the page header"
  slot :search, doc: "the page's own search, in place of the global one"
  slot :inner_block, required: true

  def app(assigns) do
    areas = areas(assigns.current_user, assigns.nav)
    active = area_key(assigns.current_path)

    header_tabs = tabs_for(assigns, areas, active)

    assigns =
      assigns
      |> assign(:areas, areas)
      |> assign(:active_area, active)
      |> assign(:header_tabs, header_tabs)
      # A page whose header has the room keeps its tabs beside the title on
      # a tablet too (TabletInbox board); the others get a row of their own.
      |> assign(:inline_tabs?, assigns.inline_tabs and header_tabs != [])

    ~H"""
    <div class="min-h-screen bg-base-200">
      <HllConditionalActionsWeb.TicketComponents.alert_listener :if={@current_user} />
      <.rail current_user={@current_user} areas={@areas} active={@active_area} nav={@nav} />

      <div class="xl:pl-[6.5rem]">
        <header :if={@header} id="app-header" class="shell-header">
          <div class="flex min-h-[4.25rem] items-center gap-2.5 px-4 pt-4 md:min-h-[5.5rem] md:gap-2.5 md:px-6 md:pt-6 xl:min-h-[5.75rem] xl:gap-3 xl:pl-2 xl:pr-7 xl:pt-0">
            <.link
              navigate={~p"/"}
              aria-label={gettext("Conditional Actions")}
              class={[
                "logo-tile shrink-0 xl:hidden",
                if(@greeting || @phone_scope,
                  do: "flex size-12 rounded-[0.9375rem]",
                  else: "hidden size-12 rounded-[0.9375rem] md:flex"
                ),
                @greeting && "max-md:size-11 max-md:rounded-[0.875rem]"
              ]}
            >
              <.logo_chevrons class="size-6" />
            </.link>

            <.link
              :if={@back}
              navigate={@back}
              id="header-back"
              aria-label={@back_label || gettext("Back")}
              class="icon-round size-11 shrink-0"
            >
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>

            <%!-- Phone and tablet: the page's greeting in place of its title
                  (MobileBriefing and TabletBriefing boards). --%>
            <div
              :if={@greeting}
              id="page-greeting"
              class="flex min-w-0 flex-1 flex-col gap-px md:ml-1.5 md:gap-0.5 xl:hidden"
            >
              <p
                :if={@greeting_eyebrow}
                class="flex items-center gap-1.5 truncate text-xs text-muted md:text-[0.8125rem] md:text-subtle"
              >
                <.icon name="hero-calendar" class="hidden size-4 shrink-0 md:inline-block" />
                {@greeting_eyebrow}
              </p>
              <h1 class="truncate font-display text-[1.3125rem] font-semibold tracking-[-0.01em] md:text-[1.75rem] md:tracking-[-0.02em]">
                {@greeting}
              </h1>
            </div>

            <.scope_switcher
              :if={@phone_scope && @nav && @nav.servers != []}
              id="header-scope-phone"
              class="relative min-w-0 flex-1 md:hidden"
              wide
              nav={@nav}
              current_user={@current_user}
              current_path={@current_path}
            />

            <div class={[
              "min-w-0 flex-1 md:max-w-[45%] md:flex-none",
              @greeting && "hidden xl:block",
              @phone_scope && "max-md:hidden"
            ]}>
              <p :if={@crumb || @eyebrow} class="truncate text-[0.8125rem] text-muted">
                {@crumb || @eyebrow}
              </p>
              <div class="flex min-w-0 items-center gap-3">
                <h1
                  id="page-title"
                  class="truncate font-display text-[1.75rem] font-semibold leading-[1.1] tracking-[-0.02em] md:text-[1.875rem]"
                >
                  {@page_title}
                </h1>
                <.pill
                  :for={badge <- @badges}
                  id={Map.get(badge, :id)}
                  tone={badge_tone(badge.tone)}
                  class="max-sm:hidden"
                >
                  {badge.label}
                </.pill>
                <span :if={@page_meta} class="hidden truncate text-sm text-muted lg:inline">
                  {@page_meta}
                </span>
              </div>
              <p :if={@page_subtitle} class="line-clamp-2 text-[0.8125rem] text-muted md:truncate">
                {@page_subtitle}
              </p>
            </div>

            <.header_tabs
              :if={@header_tabs != []}
              id="section-tabs"
              tabs={@header_tabs}
              label={@page_title}
              class={["ml-1 hidden xl:flex", @inline_tabs? && "md:flex"]}
            />

            <%!-- Beside a greeting the greeting takes the room (TabletBriefing). --%>
            <div class={["hidden flex-1", if(@greeting, do: "xl:block", else: "md:block")]}></div>

            <div class="flex shrink-0 items-center gap-2 md:gap-3">
              <.scope_switcher
                :if={@scope && @nav && @nav.servers != [] && scoped_area?(@current_path)}
                id="header-scope"
                short={@inline_tabs?}
                tag={@scope_tag}
                nav={@scope_nav || @nav}
                current_user={@current_user}
                current_path={@current_path}
              />

              <%!-- The search comes first on a wide screen, after the scope
                    on a tablet (Briefing and TabletBriefing boards). --%>
              <div class="flex items-center gap-3 xl:-order-1">
                <%= if @search != [] do %>
                  {render_slot(@search)}
                <% else %>
                  <%!-- Beside the area's tabs the boards leave the search and
                        the bell out on a wide screen (Ctrl K still opens it). --%>
                  <.search_trigger
                    :if={@current_user && @global_search}
                    class={[@header_tabs != [] && "xl:hidden", @phone_scope && "max-md:hidden"]}
                  />
                <% end %>
              </div>

              <%!-- On a phone the bell makes room for the page's buttons, except
                    beside a greeting, whose page shows no buttons there
                    (MobileBriefing board). --%>
              <.live_component
                :if={@bell && @current_user}
                module={HllConditionalActionsWeb.NotificationsPanel}
                id="notifications"
                current_user={@current_user}
                nav={@nav}
                compact={@actions != [] and is_nil(@greeting) and not @phone_scope}
                class={@header_tabs != [] && if(@inline_tabs?, do: "md:hidden", else: "xl:hidden")}
              />

              <div :if={@actions != []} class={["contents", @phone_scope && "max-md:hidden"]}>
                {render_slot(@actions)}
              </div>
            </div>
          </div>

          <.header_tabs
            :if={@header_tabs != []}
            id="section-tabs-mobile"
            tabs={@header_tabs}
            label={@page_title}
            class={["mx-4 mt-3 flex overflow-x-auto md:mx-6 xl:hidden", @inline_tabs? && "md:hidden"]}
          />
        </header>

        <%!-- Clipped sideways: a page that overflows a phone's width must
              not widen the layout, or the fixed tab bar leaves the screen. --%>
        <main class={[
          "relative overflow-x-clip px-4 pt-3 md:px-6 md:pt-4 xl:pb-7 xl:pl-2 xl:pr-7 xl:pt-5",
          !@header && "md:pt-5",
          if(@tab_bar, do: "pb-32 md:pb-36", else: "pb-8")
        ]}>
          <div class="mx-auto max-w-[120rem] space-y-5">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <.tab_bar
        :if={@tab_bar && @current_user}
        id="tab-bar"
        areas={@areas}
        active={@active_area}
        nav={@nav}
      />

      <.live_component
        :if={@current_user}
        module={HllConditionalActionsWeb.MoreSheet}
        id="more-sheet"
        current_user={@current_user}
        current_path={@current_path}
        nav={@nav}
        areas={@areas}
        active={@active_area}
      />

      <.live_component
        :if={@current_user}
        module={HllConditionalActionsWeb.CommandPalette}
        id="command-palette"
        current_user={@current_user}
        nav={@nav}
      />

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # The field that opens the command palette: a field on wide screens, a
  # round button below. It only looks like an input; the palette is where
  # the typing happens.
  attr :class, :any, default: nil

  defp search_trigger(assigns) do
    ~H"""
    <button
      type="button"
      id="global-search"
      class={["search-trigger", @class]}
      aria-label={gettext("Search players, rules, matches…")}
      aria-haspopup="dialog"
      aria-controls="command-palette-dialog"
      data-open-palette
    >
      <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
      <span class="search-trigger-text">{gettext("Search players, rules, matches…")}</span>
      <kbd class="search-trigger-kbd">Ctrl K</kbd>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :tabs, :list, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  # The pages of the area, as pill tabs beside the title. A tab can open a
  # section ("Configurar tickets"), drawn as a hairline and a small label.
  defp header_tabs(assigns) do
    ~H"""
    <nav id={@id} aria-label={@label} class={["header-tabs", @class]}>
      <%= for tab <- @tabs do %>
        <span :if={tab[:section]} class="header-tabs-section">
          <span class="header-tabs-rule" aria-hidden="true"></span>
          {tab.section}
        </span>
        <.link
          navigate={if !tab[:patch], do: tab.path}
          patch={if tab[:patch], do: tab.path}
          aria-current={tab.active && "page"}
          class="header-tab"
        >
          {tab.label}
          <span :if={tab[:count]} class="header-tab-count">{tab.count}</span>
        </.link>
      <% end %>
    </nav>
    """
  end

  # ── Rail ───────────────────────────────────────────────────────────────────

  attr :current_user, :map, default: nil
  attr :areas, :list, required: true
  attr :active, :atom, default: nil
  attr :nav, :map, default: nil

  # The permanent icon rail from xl up: one entry per area, Ajustes and the
  # account at the bottom.
  defp rail(assigns) do
    {main, bottom} = Enum.split_with(assigns.areas, &(&1.key != :settings))
    assigns = assign(assigns, main: main, bottom: bottom)

    ~H"""
    <aside
      id="rail"
      class="fixed inset-y-0 left-0 z-40 hidden w-[6.5rem] flex-col items-center gap-1 overflow-y-auto py-5 xl:flex"
      aria-label={gettext("Navigation")}
    >
      <.link
        navigate={~p"/"}
        aria-label={gettext("Conditional Actions")}
        class="logo-tile mb-5 flex size-13 shrink-0 items-center justify-center rounded-2xl"
      >
        <.logo_chevrons class="size-7" />
      </.link>

      <.rail_item :for={area <- @main} area={area} active={@active == area.key} />
      <div class="flex-1"></div>
      <.rail_item :for={area <- @bottom} area={area} active={@active == area.key} />

      <.account_menu :if={@current_user} current_user={@current_user} nav={@nav} />
    </aside>
    """
  end

  attr :area, :map, required: true
  attr :active, :boolean, default: false

  defp rail_item(assigns) do
    ~H"""
    <.link
      navigate={@area.path}
      id={"rail-#{@area.key}"}
      aria-current={@active && "page"}
      class="rail-item"
    >
      <.icon name={@area.icon} class="size-[1.375rem]" />
      <span class="max-w-full truncate px-1">{@area.label}</span>
      <span :if={@area.badge > 0} class="rail-badge" data-nav-badge>
        {badge_text(@area.badge)}
      </span>
    </.link>
    """
  end

  attr :current_user, :map, required: true
  attr :nav, :map, default: nil

  # The avatar at the foot of the rail, and what it opens: the account, the
  # theme and the language of this browser, the version and signing out.
  defp account_menu(assigns) do
    ~H"""
    <div class="relative mt-2.5" x-data="{ menu: false }" id="account-menu">
      <button
        type="button"
        id="account-menu-button"
        class="avatar-button size-11"
        aria-label={gettext("My account")}
        aria-haspopup="menu"
        aria-controls="account-menu-panel"
        x-ref="trigger"
        x-on:click.stop="menu = !menu"
        x-bind:aria-expanded="menu"
      >
        {initials(@current_user)}
      </button>

      <div
        id="account-menu-panel"
        class="account-menu"
        role="menu"
        x-show="menu"
        x-cloak
        x-on:click.outside="menu = false"
        x-on:keydown.escape.window="menu = false"
        x-transition.opacity.duration.120ms
      >
        <div class="flex items-center gap-3 px-2 pb-3 pt-1">
          <span class="avatar-button size-10 text-[0.8125rem]">{initials(@current_user)}</span>
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold">
              {@current_user.name || @current_user.username}
            </p>
            <p class="truncate text-xs text-muted">{role_name(@current_user)}</p>
          </div>
        </div>

        <.link navigate={~p"/account"} role="menuitem" class="account-menu-item">
          <.icon name="hero-user-circle" class="size-[1.125rem] text-muted" />
          {gettext("My account")}
        </.link>

        <div class="account-menu-rule"></div>

        <p class="account-menu-label">{gettext("Theme")}</p>
        <.scheme_choice id="account-scheme" />

        <p class="account-menu-label">{gettext("Language")}</p>
        <div class="grid grid-cols-3 gap-1 px-1">
          <.link
            :for={locale <- Locale.supported()}
            href={~p"/locale/#{locale}?#{[return_to: "/"]}"}
            class={[
              "account-menu-chip",
              locale == Gettext.get_locale(HllConditionalActionsWeb.Gettext) && "is-current"
            ]}
          >
            {locale_short(locale)}
          </.link>
        </div>

        <div class="account-menu-rule"></div>

        <button
          :if={Accounts.can?(@current_user, :manage_users)}
          type="button"
          role="menuitem"
          class="account-menu-item"
          phx-click={show_dialog("about-rail")}
        >
          <.icon name="hero-information-circle" class="size-[1.125rem] text-muted" />
          <span class="flex-1 text-left">{gettext("About")}</span>
          <span class="font-mono text-[0.6875rem] text-muted">{Updates.current_version()}</span>
        </button>

        <.link
          href={~p"/logout"}
          method="delete"
          role="menuitem"
          id="account-menu-logout"
          class="account-menu-item text-error"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-[1.125rem]" />
          {gettext("Sign out")}
        </.link>
      </div>

      <.about_dialog
        :if={Accounts.can?(@current_user, :manage_users)}
        id="about-rail"
        status={Updates.status()}
      />
    </div>
    """
  end

  @doc """
  The three-way theme choice (dark, light, system) of this browser, bound to
  Petal's colour scheme contract. Used by the account menu and the "Mais"
  sheet.
  """
  attr :id, :string, required: true
  attr :size, :string, default: "sm", values: ~w(sm lg)

  def scheme_choice(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="PetalColorScheme"
      data-variant="menu"
      role="radiogroup"
      aria-label={gettext("Theme")}
      class={["scheme-choice", @size == "lg" && "scheme-choice--lg"]}
    >
      <button type="button" role="radio" data-scheme="dark" class="scheme-choice-option">
        <.icon name="hero-moon" class="size-[0.9375rem]" /> {gettext("Dark")}
      </button>
      <button type="button" role="radio" data-scheme="light" class="scheme-choice-option">
        <.icon name="hero-sun" class="size-[0.9375rem]" /> {gettext("Light")}
      </button>
      <button type="button" role="radio" data-scheme="system" class="scheme-choice-option">
        <.icon name="hero-computer-desktop" class="size-[0.9375rem]" /> {gettext("System")}
      </button>
    </div>
    """
  end

  # ── Tab bar (phone and tablet) ─────────────────────────────────────────────

  @doc false
  attr :id, :string, required: true
  attr :areas, :list, required: true
  attr :active, :atom, default: nil
  attr :nav, :map, default: nil
  attr :more_active, :boolean, default: false
  attr :in_sheet, :boolean, default: false

  # The floating bar under the thumb: Briefing, Ao vivo, Regras and Caixa on
  # a phone, Comunidade and Jogadores too on a tablet, and "Mais" for the
  # rest. Hidden from xl up, where the rail owns navigation.
  def tab_bar(assigns) do
    by_key = Map.new(assigns.areas, &{&1.key, &1})

    tabs =
      for key <- [:briefing, :live, :rules, :inbox, :community, :players],
          area = by_key[key],
          area != nil,
          do: area

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav id={@id} class="tab-bar xl:hidden" aria-label={gettext("Navigation")}>
      <.link
        :for={area <- @tabs}
        navigate={area.path}
        id={"#{@id}-#{area.key}"}
        aria-current={!@more_active && @active == area.key && "page"}
        class={["tab-bar-item", area.key in [:community, :players] && "max-md:hidden"]}
      >
        <span class="relative">
          <.icon name={area.icon} class="size-5" />
          <span :if={area.badge > 0} class="tab-bar-badge" data-nav-badge={!@in_sheet}>
            {badge_text(area.badge)}
          </span>
        </span>
        <span class="max-w-full truncate">{area.label}</span>
      </.link>

      <button
        type="button"
        id={"#{@id}-more"}
        class="tab-bar-item"
        aria-current={@more_active && "page"}
        aria-haspopup="dialog"
        aria-controls="more-sheet-dialog"
        phx-click={
          if @in_sheet,
            do: JS.dispatch("app:close-dialog", to: "#more-sheet-dialog"),
            else: open_more()
        }
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
        <span>{gettext("More")}</span>
      </button>
    </nav>
    """
  end

  defp open_more do
    "more-sheet-dialog"
    |> show_dialog()
    |> JS.push("open", target: "#more-sheet")
  end

  # ── Scope switcher ─────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :nav, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_path, :string, required: true
  attr :class, :any, default: "relative hidden md:block"
  attr :wide, :boolean, default: false, doc: "the pill fills its row (phones)"
  attr :tag, :string, default: nil, doc: ~s(a word after the server's name, "novo")
  attr :short, :boolean, default: false, doc: "below xl, \"Servers\" for all of them"

  # The server the page is about - or all of them - as a pill in the header.
  # Switching keeps the page: from one server's leaderboard to the other's.
  @doc false
  def scope_switcher(assigns) do
    ~H"""
    <div class={@class} x-data="{ open: false }" id={@id}>
      <button
        type="button"
        id={"#{@id}-button"}
        class={["scope-pill", @wide && "w-full max-w-none text-left"]}
        x-on:click="open = !open"
        x-bind:aria-expanded="open"
        aria-haspopup="menu"
        aria-controls={"#{@id}-menu"}
      >
        <%= if @nav.server do %>
          <img src={server_art(@nav.server)} alt="" class="size-9 shrink-0 rounded-full object-cover" />
          <span class={["truncate", if(@wide, do: "min-w-0 flex-1", else: "max-w-44")]}>
            {@nav.server.name}
          </span>
          <%!-- The other game is worth a word (Vietnam board). --%>
          <span :if={@tag} class="scope-tag">{@tag}</span>
          <span
            :if={!@tag && @nav.server.game in [:hllv, "hllv"]}
            class="scope-tag scope-tag--vietnam max-md:hidden"
          >
            {gettext("HLL Vietnam")}
          </span>
          <span
            class={["size-2 shrink-0 rounded-full", stream_dot(@nav.status)]}
            title={Labels.stream_status(@nav.status)}
          ></span>
        <% else %>
          <span class="scope-count">{length(@nav.servers)}</span>
          <span :if={@short} class="truncate xl:hidden">{gettext("Servers")}</span>
          <span class={["truncate", @short && "max-xl:hidden"]}>{gettext("All servers")}</span>
        <% end %>
        <.icon name="hero-chevron-down" class="size-4 shrink-0 text-muted" />
      </button>

      <div
        id={"#{@id}-menu"}
        role="menu"
        class="scope-menu"
        x-show="open"
        x-cloak
        x-transition.opacity.duration.100ms
        x-on:click.outside="open = false"
        x-on:keydown.escape.window="open = false"
      >
        <.scope_options nav={@nav} current_user={@current_user} current_path={@current_path} />
      </div>
    </div>
    """
  end

  attr :nav, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_path, :string, required: true

  @doc false
  def scope_options(assigns) do
    ~H"""
    <p class="px-2 pb-1.5 pt-1 text-[0.6875rem] font-medium uppercase tracking-wide text-muted">
      {gettext("Servers")}
    </p>

    <.link
      navigate={~p"/"}
      role="menuitem"
      class={["scope-menu-item", is_nil(@nav.server) && "is-current"]}
    >
      <span class="scope-count size-7 text-[0.6875rem]">{length(@nav.servers)}</span>
      <span class="flex-1 text-sm">{gettext("All servers")}</span>
      <.icon :if={is_nil(@nav.server)} name="hero-check" class="size-4 shrink-0 text-primary" />
    </.link>

    <.link
      :for={server <- @nav.servers}
      navigate={Nav.switch_path(@current_path, server.id)}
      role="menuitem"
      class={["scope-menu-item", @nav.server && @nav.server.id == server.id && "is-current"]}
    >
      <img src={server_art(server)} alt="" class="size-7 shrink-0 rounded-full object-cover" />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm">{server.name}</span>
        <span class="block truncate text-xs text-muted">{Labels.game(server.game)}</span>
      </span>

      <.icon
        :if={@nav.server && @nav.server.id == server.id}
        name="hero-check"
        class="size-4 shrink-0 text-primary"
      />
    </.link>

    <div :if={Accounts.can?(@current_user, :manage_servers)} class="my-1 h-px bg-base-300"></div>

    <.link
      :if={Accounts.can?(@current_user, :manage_servers)}
      navigate={~p"/servers/new"}
      role="menuitem"
      class="scope-menu-item"
    >
      <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-secondary">
        <.icon name="hero-plus" class="size-4 text-subtle" />
      </span>
      <span class="flex-1 text-sm">{gettext("Add a server")}</span>
    </.link>
    """
  end

  defp stream_dot(:connected), do: "bg-primary"
  defp stream_dot(:connecting), do: "bg-warning"
  defp stream_dot({:error, _reason}), do: "bg-error"
  defp stream_dot(_status), do: "bg-base-300"

  # ── Flash ──────────────────────────────────────────────────────────────────

  @doc """
  Shows the flash group: toasts at the bottom right (above the tab bar on a
  phone), and the connection notices.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="toast-stack">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show_toast(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show_toast(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # A toast is a flex row: shown with `display: flex`, not the block that
  # `JS.show/1` would put on it.
  defp show_toast(selector) do
    selector
    |> then(
      &JS.show(
        to: &1,
        display: "flex",
        time: 300,
        transition:
          {"transition-all ease-out duration-300", "opacity-0 translate-y-4",
           "opacity-100 translate-y-0"}
      )
    )
    |> JS.remove_attribute("hidden", to: selector)
  end

  defp locale_short("pt_BR"), do: "Português"
  defp locale_short("es"), do: "Español"
  defp locale_short("en"), do: "English"
  defp locale_short(locale), do: locale

  # ── About ──────────────────────────────────────────────────────────────────

  # The dialog is plain markup rather than the `.modal` component, which renders
  # itself open off `:if`. This one is opened by a click.
  attr :id, :string, required: true
  attr :status, :map, required: true

  @doc false
  def about_dialog(assigns) do
    ~H"""
    <dialog id={@id} class="app-dialog" aria-labelledby={"#{@id}-title"}>
      <div class="max-h-[85vh] w-[min(42rem,92vw)] overflow-y-auto rounded-[1.625rem] border border-base-300 bg-base-100 p-5 shadow-figma-card-large sm:p-6">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 id={"#{@id}-title"} class="font-display text-xl font-semibold">{gettext("About")}</h2>

            <p class="mt-0.5 text-label-small text-muted">
              {gettext("Conditional Actions for Hell Let Loose")}
            </p>
          </div>

          <form method="dialog">
            <button class="icon-round size-8" aria-label={gettext("Close")}>
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <.link
            href="https://github.com/fxsobr/hll_conditional_actions/wiki"
            target="_blank"
            rel="noopener noreferrer"
            class="chip-button"
          >
            <.icon name="hero-book-open" class="size-4" /> {gettext("Documentation")}
          </.link>

          <.link
            href="https://github.com/fxsobr/hll_conditional_actions/issues"
            target="_blank"
            rel="noopener noreferrer"
            class="chip-button"
          >
            <.icon name="hero-bug-ant" class="size-4" /> {gettext("Report an issue")}
          </.link>

          <.link
            href="https://discord.com/invite/zpSQQef"
            target="_blank"
            rel="noopener noreferrer"
            class="chip-button"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" /> {gettext("CRCON Discord")}
          </.link>
        </div>

        <dl class="mt-5 space-y-1 text-sm">
          <div class="flex flex-wrap gap-x-2">
            <dt class="text-muted">{gettext("Running:")}</dt>

            <dd class="font-medium">{Updates.current_version()}</dd>
          </div>

          <div :if={@status.latest} class="flex flex-wrap gap-x-2">
            <dt class="text-muted">{gettext("Latest release:")}</dt>

            <dd class="font-medium">{@status.latest.tag}</dd>
          </div>

          <div :if={@status.checked_at} class="flex flex-wrap gap-x-2">
            <dt class="text-muted">{gettext("Last checked:")}</dt>

            <dd>{format_checked_at(@status.checked_at)}</dd>
          </div>
        </dl>

        <p :if={@status.update_available?} class="mt-4 rounded-2xl bg-warning/10 p-3 text-sm">
          <.icon name="hero-arrow-up-circle" class="size-4 text-warning" /> {gettext(
            "A newer release is available."
          )}
        </p>

        <p
          :if={not @status.update_available? and @status.latest}
          class="mt-4 rounded-2xl bg-primary/10 p-3 text-sm"
        >
          <.icon name="hero-check-circle" class="size-4 text-primary" /> {gettext(
            "You are up to date."
          )}
        </p>

        <p :if={@status.error} class="mt-4 text-sm text-muted">
          {gettext("GitHub could not be reached, so this may be out of date.")}
        </p>

        <p :if={@status.releases == [] and is_nil(@status.error)} class="mt-4 text-sm text-muted">
          {gettext("No releases have been published yet.")}
        </p>

        <section :for={release <- @status.releases} class="mt-6 border-t border-base-300 pt-4">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h3 class="text-title-small">{release.name}</h3>

            <p :if={release.published_at} class="text-label-small text-muted">
              {format_published_at(release.published_at)}
            </p>
          </div>

          <div class="mt-2 text-sm leading-relaxed">
            {ReleaseNotes.to_html(release.notes)}
          </div>

          <.link
            href={release.url}
            target="_blank"
            rel="noopener noreferrer"
            class="link mt-2 inline-block text-label-small"
          >
            {gettext("Read it on GitHub")}
          </.link>
        </section>
      </div>
    </dialog>
    """
  end

  defp format_checked_at(at) do
    Calendar.strftime(at, gettext("%m/%d/%Y %H:%M UTC"))
  end

  defp format_published_at(at) do
    Calendar.strftime(at, gettext("%m/%d/%Y"))
  end

  # ── Areas ──────────────────────────────────────────────────────────────────

  @doc """
  The areas of the navigation the user can open, in rail order, each with
  its icon, the page it opens, its badge and its pages (the header tabs).

  "Ao vivo" opens the cockpit of the server in scope, or of the first
  server; "Módulos" the marketplace of the same server.
  """
  @spec areas(map() | nil, map() | nil) :: [map()]
  def areas(user, nav) do
    scoped = nav && nav[:server]
    servers = (nav && nav[:servers]) || []
    home = scoped || List.first(servers)
    base = scoped && "/servers/#{scoped.id}"

    [
      %{key: :briefing, icon: "hero-squares-2x2", path: "/", tabs: []},
      live_area(user, nav, home, base),
      rules_area(user, nav, base),
      inbox_area(user, nav, base),
      community_area(user, nav, base),
      %{
        key: :players,
        icon: "hero-users",
        path: "/players",
        tabs: [],
        permission: :view_stats
      },
      %{
        key: :modules,
        icon: "hero-square-3-stack-3d",
        path: home && "/servers/#{home.id}/marketplace",
        tabs: [],
        permission: :manage_servers
      },
      settings_area(user)
    ]
    |> Enum.filter(&(&1 && &1.path && allowed?(user, Map.get(&1, :permission))))
    |> Enum.map(fn area ->
      area
      |> Map.put(:label, area_label(area.key))
      |> Map.put(:badge, area_badge(area.key, nav))
    end)
  end

  # Feed is the cockpit (Cockpit and Leaderboard boards); it is "quiet": the
  # cockpit has these views in its own content, so on it the header shows
  # no tabs.
  defp live_area(user, nav, home, base) do
    scores = (base || "") <> "/leaderboard"

    tabs =
      visible_tabs(user, nav, [
        home &&
          %{
            label: gettext("Feed"),
            path: "/servers/#{home.id}",
            permission: :view_servers,
            quiet: true
          },
        %{label: gettext("Scoreboard"), path: scores, permission: :view_stats, feature: :stats},
        %{
          label: gettext("Squads"),
          path: scores <> "?view=squads",
          permission: :view_stats,
          feature: :stats
        }
      ])

    path =
      cond do
        home && Accounts.can?(user, :view_servers) -> "/servers/#{home.id}"
        tabs != [] -> hd(tabs).path
        true -> nil
      end

    %{key: :live, icon: "hero-signal", path: path, tabs: tabs}
  end

  defp rules_area(user, nav, base) do
    tabs =
      visible_tabs(user, nav, [
        %{label: gettext("Rules"), path: (base || "") <> "/rules"},
        %{
          label: gettext("History"),
          path: if(base, do: base <> "/history", else: "/executions"),
          permission: :view_executions
        },
        %{label: gettext("Simulator"), path: "/rules/simulate"}
      ])

    %{
      key: :rules,
      icon: "hero-bolt",
      path: (base || "") <> "/rules",
      tabs: tabs,
      permission: :view_rules,
      feature: :rules
    }
    |> only_with_feature(nav)
  end

  defp inbox_area(user, nav, base) do
    tickets = (base || "") <> "/tickets"

    config =
      visible_tabs(user, nav, [
        %{
          label: gettext("Assistant"),
          path: tickets <> "/setup",
          permission: :manage_tickets,
          feature: :tickets
        },
        %{
          label: gettext("Settings"),
          path: tickets <> "/settings",
          permission: :manage_tickets,
          feature: :tickets
        },
        %{
          label: gettext("Metrics"),
          path: tickets <> "/metrics",
          permission: :view_tickets,
          feature: :tickets
        }
      ])

    config =
      case config do
        [first | rest] -> [Map.put(first, :section, gettext("Configure tickets")) | rest]
        [] -> []
      end

    %{
      key: :inbox,
      icon: "hero-inbox",
      path: "/inbox",
      tabs: [%{label: gettext("Incoming"), path: "/inbox"} | config],
      permission: :view_executions
    }
  end

  defp community_area(user, nav, base) do
    tabs =
      visible_tabs(user, nav, [
        %{
          label: gettext("Seasons"),
          path: (base || "") <> "/seasons",
          permission: :view_progression,
          feature: :progression,
          prefix: true
        },
        %{
          label: gettext("Achievements"),
          path: (base || "") <> "/achievements",
          permission: :view_progression,
          feature: :progression,
          prefix: true
        },
        %{
          label: gettext("Matches"),
          path: (base || "") <> "/matches",
          permission: :view_stats,
          feature: :stats,
          prefix: true
        },
        %{
          label: gettext("VIP shop"),
          path: "/vip-shop",
          permission: :manage_integrations,
          feature: :vip_shop,
          prefix: true
        }
      ])

    case tabs do
      [] -> nil
      [first | _rest] -> %{key: :community, icon: "hero-trophy", path: first.path, tabs: tabs}
    end
  end

  defp settings_area(user) do
    people =
      visible_tabs(user, nil, [
        %{label: gettext("Users"), path: "/users", permission: :manage_users, prefix: true},
        %{label: gettext("Roles"), path: "/roles", permission: :manage_roles, prefix: true}
      ])

    %{key: :settings, icon: "hero-cog-6-tooth", path: "/settings", tabs: people}
  end

  # The pages whose content does not change with the server - Ajustes and
  # the VIP shop - have no scope to pick (Settings and VipShop boards).
  defp scoped_area?(path) do
    area_key(path) != :settings and not String.starts_with?(path, "/vip-shop")
  end

  defp only_with_feature(area, nav) do
    if Nav.feature?(nav, area[:feature]), do: area
  end

  defp visible_tabs(user, nav, tabs) do
    Enum.filter(tabs, fn tab ->
      tab && allowed?(user, tab[:permission]) &&
        (nav == nil or Nav.feature?(nav, tab[:feature]))
    end)
  end

  defp area_label(:briefing), do: gettext("Briefing")
  defp area_label(:live), do: gettext("Live")
  defp area_label(:rules), do: gettext("Rules")
  defp area_label(:inbox), do: gettext("Inbox")
  defp area_label(:community), do: gettext("Community")
  defp area_label(:players), do: gettext("Players")
  defp area_label(:modules), do: gettext("Modules")
  defp area_label(:settings), do: gettext("Settings")

  # Caixa counts what waits in the inbox: attention items and open tickets.
  defp area_badge(:inbox, %{inbox: count}) when is_integer(count), do: count
  defp area_badge(_key, _nav), do: 0

  defp badge_tone(tone) when tone in ["primary", "success", "live"], do: "live"
  defp badge_tone(tone) when tone in ["engine", "simulating"], do: "simulating"
  defp badge_tone(tone) when tone in ["warning", "error", "info"], do: tone
  defp badge_tone(_tone), do: "neutral"

  defp badge_text(count) when count > 99, do: "99+"
  defp badge_text(count), do: count

  @doc """
  The area a path belongs to.

      iex> alias HllConditionalActionsWeb.Layouts
      iex> Layouts.area_key("/servers/3/leaderboard")
      :live
      iex> Layouts.area_key("/servers/3/edit")
      :settings
      iex> Layouts.area_key("/tickets/12")
      :inbox
  """
  @spec area_key(String.t()) :: atom()
  def area_key(path) do
    case Regex.run(~r{^/servers/\d+(/[a-z_-]+)?}, path) do
      [_all] -> :live
      [_all, section] -> section_area(section)
      nil -> section_area(path)
    end
  end

  defp section_area("/"), do: :briefing
  defp section_area(path), do: path |> String.split("/", trim: true) |> hd() |> top_area()

  defp top_area(section) when section in ~w(feed leaderboard), do: :live
  defp top_area(section) when section in ~w(rules history executions), do: :rules
  defp top_area(section) when section in ~w(inbox attention tickets), do: :inbox

  defp top_area(section) when section in ~w(seasons achievements matches vip-shop),
    do: :community

  defp top_area("players"), do: :players
  defp top_area("marketplace"), do: :modules
  defp top_area(_settings), do: :settings

  # The tabs over the page: its own, or the pages of its area when it is one
  # of them. None on a detail page (one with a back button).
  defp tabs_for(%{tabs: tabs, current_path: path}, _areas, _active) when is_list(tabs) do
    Enum.map(tabs, fn tab ->
      tab
      |> Map.put_new(:active, active_tab?(path, tab))
      |> Map.put_new(:count, nil)
    end)
  end

  defp tabs_for(%{tabs: :auto, back: nil, current_path: path} = assigns, areas, active) do
    area = Enum.find(areas, &(&1.key == active))
    nav = assigns.nav || %{}
    counts = nav[:tab_counts] || %{}
    full = if nav[:query] in [nil, ""], do: path, else: path <> "?" <> nav[:query]

    with %{tabs: [_one, _two | _rest] = tabs} <- area,
         %{} = current <- current_tab(tabs, path, full),
         false <- Map.get(current, :quiet, false) do
      Enum.map(tabs, fn tab ->
        tab
        |> Map.put(:active, tab.path == current.path)
        |> Map.put(:count, Map.get(counts, tab.path))
      end)
    else
      _no_tabs -> []
    end
  end

  defp tabs_for(_assigns, _areas, _active), do: []

  # The tab of the page: the one whose link, query included, is the page's
  # ("Squads" is the leaderboard with ?view=squads), else the one whose path
  # is.
  defp current_tab(tabs, path, full) do
    Enum.find(tabs, &(&1.path == full)) ||
      Enum.find(tabs, &(not String.contains?(&1.path, "?") and active_tab?(path, &1)))
  end

  defp active_tab?(path, %{path: tab_path} = tab) do
    path == tab_path or
      (Map.get(tab, :prefix, false) and String.starts_with?(path, tab_path <> "/"))
  end

  # ── Shared bits ────────────────────────────────────────────────────────────

  attr :class, :any, default: "size-7"

  @doc false
  def logo_chevrons(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      fill="none"
      stroke="currentColor"
      stroke-width="2.4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="m5 11 7-5 7 5" /><path d="m5 17 7-5 7 5" />
    </svg>
    """
  end

  defp allowed?(_user, nil), do: true
  defp allowed?(user, permission), do: Accounts.can?(user, permission)

  @doc false
  def role_name(%{role: %{} = role}),
    do: HllConditionalActionsWeb.SettingsComponents.role_label(role)

  def role_name(_user), do: nil

  @doc """
  The letters of a user's avatar: the first two of a single name ("MA" for
  Marcelo), the initials of the first two words otherwise.

      iex> HllConditionalActionsWeb.Layouts.initials(%{name: "Marcelo"})
      "MA"
      iex> HllConditionalActionsWeb.Layouts.initials(%{name: "Claude (dev)", username: "c"})
      "CD"
  """
  def initials(%{name: name} = user) when is_binary(name) and name != "" do
    case String.split(name, ~r/[^\p{L}\p{N}]+/u, trim: true) do
      [] -> initials(Map.delete(user, :name))
      [word] -> word |> String.slice(0, 2) |> String.upcase()
      [first, second | _rest] -> String.upcase(String.first(first) <> String.first(second))
    end
  end

  def initials(%{username: username}) when is_binary(username),
    do: username |> String.slice(0, 2) |> String.upcase()

  def initials(_user), do: "?"
end
