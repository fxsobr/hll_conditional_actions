defmodule HllConditionalActionsWeb.Layouts do
  @moduledoc """
  Application layouts and the chrome around every page.

  `app/1` wraps authenticated pages: a sidebar whose entries are filtered by
  the signed in user's permissions, a header with the page title, and the flash
  group. The sidebar's mobile behaviour is pure Alpine.js, so opening and
  closing the menu never touches the server.

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

  # Maps with a clear, recognisable daytime shot, for the sign in backdrop.
  @auth_art ~w(
    /images/maps/hll/carentan-day.webp
    /images/maps/hll/stmereeglise-dawn.webp
    /images/maps/hll/omahabeach-day.webp
    /images/maps/hll/foy-day.webp
    /images/maps/hll/purpleheartlane-dawn.webp
    /images/maps/hll/elsenbornridge-dawn.webp
    /images/maps/hll/driel-dawn.webp
    /images/maps/hll/stalingrad-dusk.webp
  )

  @doc """
  The shell for authenticated pages.

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

  attr :back, :string,
    default: nil,
    doc: "shows a back arrow to the left of the title, for detail screens"

  attr :back_label, :string, default: nil

  attr :badges, :list,
    default: [],
    doc: "status pills beside the title: maps of %{id, label, tone, icon}"

  slot :actions, doc: "buttons rendered on the right of the page header"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <HllConditionalActionsWeb.TicketComponents.alert_listener :if={@current_user} />
      <.sidebar current_user={@current_user} current_path={@current_path} nav={@nav} />
      <div class="lg:pl-64">
        <header class="sticky top-0 z-30 bg-base-100/85 backdrop-blur">
          <%!-- The rail and the sidebar brand are both a 4rem box with the
                hairline inside it, so the two borders land on the same row and
                read as one line across the page. --%>
          <div class="flex min-h-16 items-center gap-3 border-b border-base-300 px-4 py-2 sm:px-6">
            <button
              type="button"
              class="flex size-9 cursor-pointer items-center justify-center rounded-field text-subtle transition-colors hover:bg-base-200 hover:text-base-content lg:hidden"
              aria-label={gettext("Open the menu")}
              aria-haspopup="dialog"
              phx-click={show_dialog("mobile-sidebar")}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>

            <.link
              :if={@back}
              navigate={@back}
              aria-label={@back_label || gettext("Back")}
              class="flex size-9 shrink-0 items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </.link>

            <%!-- A floor under the title: without it a page with many actions
                  squeezes it to nothing on a phone, and nobody can tell which
                  page they are on. --%>
            <div class="min-w-28 flex-1">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <h1 class="truncate text-headline-medium">{@page_title}</h1>

                <.tone_badge
                  :for={badge <- @badges}
                  tone={badge.tone}
                  size="xs"
                  icon={Map.get(badge, :icon)}
                >
                  {badge.label}
                </.tone_badge>
              </div>

              <p :if={@page_subtitle} class="truncate text-xs text-muted">
                {@page_subtitle}
              </p>
            </div>

            <%!-- Wrapping rather than shrinking: the children are all fixed
                  size, so a `shrink` container narrower than its content just
                  spills over the right edge of a phone. --%>
            <div class="flex min-w-0 shrink flex-wrap items-center justify-end gap-2">
              {render_slot(@actions)}
              <div class="hidden h-6 w-px bg-base-300 sm:block"></div>

              <%!-- Below `sm` the switch lives in the navigation drawer
                    instead, so the sticky header stays one row tall. --%>
              <.attention_bell :if={@nav && Map.get(@nav, :attention)} nav={@nav} />
              <.color_scheme_switch id="scheme-switch" variant="dropdown" class="hidden sm:flex" />
              <.user_menu current_user={@current_user} />
            </div>
          </div>
        </header>

        <main class="p-4 pb-24 sm:p-6 lg:pb-6">
          <div class="mx-auto max-w-[120rem] space-y-6">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
      <.tab_bar current_user={@current_user} current_path={@current_path} nav={@nav} />
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # The thumb-reach navigation on phones: the four screens an admin lives in,
  # plus the drawer for everything else. Hidden from lg up, where the
  # sidebar owns navigation.
  attr :current_user, :map, default: nil
  attr :current_path, :string, required: true
  attr :nav, :map, default: nil

  defp tab_bar(assigns) do
    assigns = assign(assigns, :tabs, tab_items(assigns.current_user, assigns.nav))

    ~H"""
    <nav
      class="fixed inset-x-0 bottom-0 z-30 border-t border-base-300 bg-base-100/95 backdrop-blur lg:hidden"
      aria-label={gettext("Navigation")}
    >
      <ul class="mx-auto flex max-w-md items-stretch justify-around">
        <li :for={tab <- @tabs} class="min-w-0 flex-1">
          <.link
            navigate={tab.path}
            aria-current={active?(@current_path, tab.path) && "page"}
            class={[
              "flex flex-col items-center gap-0.5 px-1 pb-2 pt-2.5 text-[0.625rem] font-medium",
              if(active?(@current_path, tab.path),
                do: "text-primary",
                else: "text-muted"
              )
            ]}
          >
            <.icon name={tab.icon} class="size-5" />
            <span class="max-w-full truncate">{tab.label}</span>
          </.link>
        </li>

        <li class="min-w-0 flex-1">
          <button
            type="button"
            class="flex w-full cursor-pointer flex-col items-center gap-0.5 px-1 pb-2 pt-2.5 text-[0.625rem] font-medium text-muted"
            aria-haspopup="dialog"
            phx-click={show_dialog("mobile-sidebar")}
          >
            <.icon name="hero-bars-3" class="size-5" />
            <span class="max-w-full truncate">{gettext("Menu")}</span>
          </button>
        </li>
      </ul>
    </nav>
    """
  end

  # The four highest-traffic destinations the user can actually reach - of
  # the server in scope when there is one.
  defp tab_items(current_user, %{server: %{id: id}} = nav) do
    [
      %{
        label: gettext("Overview"),
        path: "/servers/#{id}",
        icon: "hero-squares-2x2",
        permission: nil
      },
      %{
        label: gettext("Live"),
        path: "/servers/#{id}/feed",
        feature: :live_feed,
        icon: "hero-signal",
        permission: :view_live_feed
      },
      %{
        label: gettext("Leaderboard"),
        path: "/servers/#{id}/leaderboard",
        feature: :stats,
        icon: "hero-trophy",
        permission: :view_stats
      },
      %{
        label: gettext("Rules"),
        path: "/servers/#{id}/rules",
        feature: :rules,
        icon: "hero-bolt",
        permission: :view_rules
      }
    ]
    |> Enum.filter(&(allowed?(current_user, &1.permission) and Nav.feature?(nav, &1[:feature])))
  end

  defp tab_items(current_user, nav) do
    [
      %{label: gettext("Overview"), path: "/", icon: "hero-squares-2x2", permission: nil},
      %{
        label: gettext("Servers"),
        path: "/servers",
        icon: "hero-server-stack",
        permission: :view_servers
      },
      %{
        label: gettext("Rules"),
        path: "/rules",
        feature: :rules,
        icon: "hero-bolt",
        permission: :view_rules
      },
      %{
        label: gettext("Attention"),
        path: "/attention",
        icon: "hero-bell-alert",
        permission: :view_executions
      }
    ]
    |> Enum.filter(&(allowed?(current_user, &1.permission) and Nav.feature?(nav, &1[:feature])))
  end

  @doc """
  The shell for pages shown to anonymous visitors, such as the login form.

  The artwork panel is decorative and hidden from assistive technology; every
  word that matters is repeated in the form panel.
  """
  attr :flash, :map, required: true
  attr :locale, :string, default: nil, doc: "the locale currently being served"
  attr :return_to, :string, default: "/login", doc: "where the language switch comes back to"
  slot :inner_block, required: true

  def auth(assigns) do
    assigns = assign(assigns, :art, Enum.random(@auth_art))

    ~H"""
    <%!-- One of the game's maps, full bleed, under a scrim that settles it
          into the page; the form floats on a frosted card over it. Everybody
          who reaches this page already has an account, so it sells nothing:
          it only has to look like the tool it opens. --%>
    <div class="auth-shell" style={"--auth-art: url('#{@art}')"}>
      <div class="auth-scrim" aria-hidden="true"></div>

      <header class="relative flex items-center gap-3 p-6 text-white sm:p-8">
        <.logo_mark class="size-10" />
        <div>
          <p class="font-semibold leading-tight">{gettext("Conditional Actions")}</p>

          <p class="text-xs text-white/60">{gettext("Hell Let Loose")}</p>
        </div>
      </header>

      <main class="relative flex flex-1 items-center justify-center px-4 py-6 sm:justify-end sm:px-12 lg:px-24">
        <div class="auth-card">
          {render_slot(@inner_block)}
          <%!-- The language belongs to the form it changes, not to the
                artwork: under the button, quiet, centred. --%>
          <div class="mt-6 flex justify-center border-t border-base-300 pt-4">
            <.locale_switch locale={@locale} return_to={@return_to} />
          </div>
        </div>
      </main>

      <footer class="relative flex flex-col items-center gap-3 p-6 text-white/70 sm:flex-row sm:justify-between sm:px-8">
        <p class="text-center text-xs text-white/45">
          {gettext("Hell Let Loose is a trademark of Team17. This is an unofficial admin tool.")}
        </p>
        <.crcon_credit />
      </footer>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # Credit to CRCON, on the sign in page.
  #
  # This app is a client: without a CRCON instance to talk to it does nothing
  # at all, and every action it takes is a CRCON call. Saying so where
  # everybody passes, with the way to reach that project, is the least it can
  # do.
  #
  # In the main column rather than beside the artwork, because the artwork
  # panel is hidden below `lg` and this should be there on a phone too.
  defp crcon_credit(assigns) do
    ~H"""
    <p class="flex flex-wrap items-center justify-center gap-x-2 gap-y-1 text-xs text-white/60">
      <span>{gettext("Powered by CRCON")}</span> <span aria-hidden="true">·</span>
      <%!-- `noopener` because a page opened from here must not get a handle on
            this one through `window.opener`. --%>
      <.link
        href="https://github.com/MarechJ/hll_rcon_tool"
        target="_blank"
        rel="noopener noreferrer"
        class="transition-colors hover:text-white hover:underline"
      >
        GitHub
      </.link>
      <span aria-hidden="true">·</span>
      <.link
        href="https://discord.com/invite/zpSQQef"
        target="_blank"
        rel="noopener noreferrer"
        class="transition-colors hover:text-white hover:underline"
      >
        Discord
      </.link>
    </p>
    """
  end

  attr :locale, :string, default: nil
  attr :return_to, :string, default: "/login"
  attr :overlay, :boolean, default: false, doc: "drawn over artwork: light text on glass"

  defp locale_switch(assigns) do
    assigns = assign(assigns, :locales, Locale.supported())

    ~H"""
    <div
      :if={length(@locales) > 1}
      class={[
        "flex items-center gap-0.5 rounded-pill p-0.5",
        if(@overlay,
          do: "bg-white/10 ring-1 ring-white/15 backdrop-blur",
          else: "border border-base-300 bg-base-100"
        )
      ]}
    >
      <.link
        :for={locale <- @locales}
        href={~p"/locale/#{locale}?#{[return_to: @return_to]}"}
        class={[
          "rounded-pill px-3 py-1 text-xs transition-colors",
          locale_tone(locale == @locale, @overlay)
        ]}
      >
        {locale_label(locale)}
      </.link>
    </div>
    """
  end

  defp locale_tone(true, true), do: "bg-white/90 font-medium text-gray-900"
  defp locale_tone(false, true), do: "text-white/70 hover:text-white"
  defp locale_tone(true, false), do: "bg-base-200 font-medium text-base-content"
  defp locale_tone(false, false), do: "text-muted hover:text-base-content"

  defp locale_label("pt_BR"), do: "Português"
  defp locale_label("es"), do: "Español"
  defp locale_label("en"), do: "English"
  defp locale_label(locale), do: locale

  attr :current_user, :map, default: nil
  attr :current_path, :string, default: "/"
  attr :nav, :map, default: nil

  # The permanent rail on lg+, and a native <dialog> drawer below it: the
  # dialog is what buys the mobile menu its focus trap, Escape handling and
  # focus restoration without a line of custom trap code.
  defp sidebar(assigns) do
    ~H"""
    <aside class="fixed inset-y-0 left-0 z-40 hidden w-64 flex-col border-r border-base-300 bg-base-100 lg:flex">
      <.sidebar_content
        id="sidebar"
        current_user={@current_user}
        current_path={@current_path}
        nav={@nav}
      />
    </aside>

    <dialog
      id="mobile-sidebar"
      class="app-drawer lg:hidden"
      aria-label={gettext("Navigation")}
      x-data
      x-on:click="if ($event.target === $el || $event.target.closest('a')) $el.close()"
    >
      <div class="flex h-full flex-col">
        <.sidebar_content
          id="mobile-sidebar-content"
          current_user={@current_user}
          current_path={@current_path}
          nav={@nav}
          closable
        />
      </div>
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :current_user, :map, default: nil
  attr :current_path, :string, required: true
  attr :nav, :map, default: nil
  attr :closable, :boolean, default: false

  defp sidebar_content(assigns) do
    ~H"""
    <div class="flex h-16 shrink-0 items-center gap-2.5 border-b border-base-300 px-4">
      <.logo_mark class="size-8 shrink-0" />
      <div class="min-w-0 flex-1">
        <p class="truncate text-title-medium leading-tight">
          {gettext("Conditional Actions")}
        </p>

        <p class="truncate text-label-small text-muted">{gettext("Hell Let Loose")}</p>
      </div>

      <form :if={@closable} method="dialog">
        <button
          class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label={gettext("Close the menu")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </form>
    </div>

    <.scope_switcher
      :if={@nav && @nav.servers != []}
      id={"#{@id}-scope"}
      nav={@nav}
      current_user={@current_user}
      current_path={@current_path}
    />
    <nav id={"#{@id}-nav"} class="flex-1 space-y-6 overflow-y-auto p-3 pl-4">
      <.nav_section
        :for={section <- nav_sections(@current_user, @nav)}
        title={section.title}
        items={section.items}
        current_path={@current_path}
      />
    </nav>
    <.version_line :if={Accounts.can?(@current_user, :manage_users)} id={@id} />
    <div :if={@current_user} class="flex shrink-0 items-center gap-2 border-t border-base-300 p-3">
      <.link
        navigate={~p"/account"}
        class="flex min-w-0 flex-1 items-center gap-2.5 rounded-box p-2 transition-colors hover:bg-base-200"
      >
        <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral text-xs font-semibold text-neutral-content">
          {initials(@current_user)}
        </div>

        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-medium leading-tight">
            {@current_user && (@current_user.name || @current_user.username)}
          </p>

          <p class="truncate text-xs text-muted">{role_name(@current_user)}</p>
        </div>
      </.link>

      <.color_scheme_switch id={"scheme-switch-#{@id}"} variant="dropdown" class="shrink-0 sm:hidden" />
    </div>
    """
  end

  # Which version is running, and a dot when GitHub has a newer one. Only shown
  # to whoever can manage users: it is the same audience that would act on it,
  # and an operator has no use for a build stamp.
  attr :id, :string, required: true

  defp version_line(assigns) do
    assigns = assign(assigns, :status, Updates.status())

    ~H"""
    <button
      type="button"
      class="flex w-full shrink-0 cursor-pointer items-center gap-2 border-t border-base-300 px-4 py-2 text-label-small text-muted transition-colors hover:bg-base-200 hover:text-base-content"
      phx-click={show_dialog("about-#{@id}")}
      aria-haspopup="dialog"
    >
      <span
        :if={@status.update_available?}
        class="size-1.5 shrink-0 rounded-full bg-warning"
        aria-hidden="true"
      />
      <span class="truncate">
        {gettext("Version:")} {Updates.current_version()}
      </span>

      <span :if={@status.update_available?} class="ml-auto shrink-0 text-warning">
        {gettext("Update")}
      </span>
    </button>
    <.about_dialog id={"about-#{@id}"} status={@status} />
    """
  end

  # The dialog is plain markup rather than the `.modal` component, which renders
  # itself open off `:if`. This one is opened by a click, like the mobile drawer.
  attr :id, :string, required: true
  attr :status, :map, required: true

  defp about_dialog(assigns) do
    ~H"""
    <dialog id={@id} class="app-dialog" aria-labelledby={"#{@id}-title"}>
      <div class="max-h-[85vh] w-[min(42rem,92vw)] overflow-y-auto rounded-box border border-base-300 bg-base-100 p-5 shadow-figma-card-large sm:p-6">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 id={"#{@id}-title"} class="text-title-large">{gettext("About")}</h2>

            <p class="mt-0.5 text-label-small text-muted">
              {gettext("Conditional Actions for Hell Let Loose")}
            </p>
          </div>

          <form method="dialog">
            <button
              class="flex size-8 cursor-pointer items-center justify-center rounded-field text-muted transition-colors hover:bg-base-200 hover:text-base-content"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </form>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <.link
            href="https://github.com/fxsobr/hll_conditional_actions/wiki"
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-book-open" class="size-4" /> {gettext("Documentation")}
          </.link>

          <.link
            href="https://github.com/fxsobr/hll_conditional_actions/issues"
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-bug-ant" class="size-4" /> {gettext("Report an issue")}
          </.link>

          <.link
            href="https://discord.com/invite/zpSQQef"
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-sm btn-outline"
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

        <p :if={@status.update_available?} class="mt-4 rounded-box bg-warning/10 p-3 text-sm">
          <.icon name="hero-arrow-up-circle" class="size-4 text-warning" /> {gettext(
            "A newer release is available."
          )}
        </p>

        <p
          :if={not @status.update_available? and @status.latest}
          class="mt-4 rounded-box bg-success/10 p-3 text-sm"
        >
          <.icon name="hero-check-circle" class="size-4 text-success" /> {gettext(
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

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :current_path, :string, required: true

  defp nav_section(assigns) do
    ~H"""
    <div>
      <p class="eyebrow px-3 pb-1.5 text-muted">{@title}</p>

      <ul class="space-y-0.5">
        <li
          :for={item <- @items}
          class="nav-item"
          data-active={to_string(active?(@current_path, item.path))}
        >
          <.link
            navigate={item.path}
            aria-current={active?(@current_path, item.path) && "page"}
            class={[
              "flex items-center gap-3 rounded-field px-3 py-2 text-sm transition-colors",
              if(active?(@current_path, item.path),
                do: "bg-primary/10 font-medium text-primary",
                else: "text-subtle hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <.icon
              name={item.icon}
              class={[
                "size-4 shrink-0",
                if(active?(@current_path, item.path),
                  do: "text-primary",
                  else: "text-muted"
                )
              ]}
            /> <span class="truncate">{item.label}</span>
            <span
              :if={Map.get(item, :badge, 0) > 0}
              class="ml-auto min-w-5 rounded-full bg-warning px-1.5 text-center text-xs font-semibold leading-5 text-warning-content"
              data-nav-badge
              title={gettext("Waiting for an admin")}
            >
              {item.badge}
            </span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :current_user, :map, default: nil

  attr :nav, :map, required: true

  # The unread Attention items: a bell with their count, opening the inbox
  # of the server being looked at, or the whole organisation's.
  defp attention_bell(assigns) do
    assigns =
      assign(assigns,
        count: assigns.nav.attention,
        path:
          if(assigns.nav[:server],
            do: "/servers/#{assigns.nav.server.id}/attention",
            else: "/attention"
          )
      )

    ~H"""
    <.link
      navigate={@path}
      id="attention-bell"
      class="attention-bell"
      aria-label={
        ngettext("1 unread item in Attention", "%{count} unread items in Attention", @count)
      }
      title={ngettext("1 unread item in Attention", "%{count} unread items in Attention", @count)}
    >
      <.icon name={if @count > 0, do: "hero-bell-alert", else: "hero-bell"} class="size-5" />
      <span :if={@count > 0} class="attention-bell-badge">{if @count > 99, do: "99+", else: @count}</span>
    </.link>
    """
  end

  defp user_menu(assigns) do
    ~H"""
    <div :if={@current_user} class="relative" x-data="{ menu: false }">
      <button
        type="button"
        class="flex cursor-pointer items-center gap-2 rounded-field px-1.5 py-1 transition-colors hover:bg-base-200"
        x-ref="usertrigger"
        x-on:click.stop="menu = !menu"
        aria-haspopup="menu"
        x-bind:aria-expanded="menu"
      >
        <div class="flex size-7 items-center justify-center rounded-full bg-neutral text-xs font-semibold text-neutral-content">
          {initials(@current_user)}
        </div>
        <span class="hidden max-w-32 truncate text-sm sm:inline">{@current_user.username}</span>
        <.icon name="hero-chevron-down" class="size-3 opacity-60" />
      </button>

      <div
        class="absolute right-0 z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
        x-show="menu"
        x-cloak
        x-on:click.outside="menu = false"
        x-on:keydown.escape.stop="menu = false; $refs.usertrigger?.focus()"
        x-effect="if (menu) $nextTick(() => $el.querySelector('a')?.focus())"
        x-on:keydown.arrow-down.prevent="(() => { const items = [...$el.querySelectorAll('a')]; const i = items.indexOf(document.activeElement); items[Math.min(i + 1, items.length - 1)]?.focus() })()"
        x-on:keydown.arrow-up.prevent="(() => { const items = [...$el.querySelectorAll('a')]; const i = items.indexOf(document.activeElement); items[Math.max(i - 1, 0)]?.focus() })()"
        x-transition.opacity.duration.150ms
      >
        <div class="px-3 py-2">
          <p class="truncate text-sm font-medium">{@current_user.name || @current_user.username}</p>

          <p class="truncate text-xs text-muted">{role_name(@current_user)}</p>
        </div>

        <div class="my-1 border-t border-base-300"></div>

        <ul class="w-full" role="menu">
          <li role="none">
            <.link
              navigate={~p"/account"}
              role="menuitem"
              class="flex items-center gap-2 rounded-field px-2.5 py-1.5 text-sm hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none"
            >
              <.icon name="hero-user-circle" class="size-4" />{gettext("My account")}
            </.link>
          </li>

          <li role="none">
            <.link
              href={~p"/logout"}
              method="delete"
              role="menuitem"
              class="flex items-center gap-2 rounded-field px-2.5 py-1.5 text-sm hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />{gettext("Sign out")}
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed right-4 top-4 z-[60] flex w-[calc(100vw-2rem)] max-w-sm flex-col gap-2"
    >
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
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
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # ── Navigation data ────────────────────────────────────────────────────────

  # Entries the signed in user has no permission for are dropped, and a section
  # with nothing left in it disappears too.
  defp nav_sections(current_user, %{server: %{id: id}} = nav) do
    base = "/servers/#{id}"

    [
      %{
        title: gettext("Server"),
        items: [
          %{label: gettext("Overview"), path: base, icon: "hero-squares-2x2", permission: nil},
          %{
            label: gettext("Live feed"),
            path: base <> "/feed",
            feature: :live_feed,
            icon: "hero-signal",
            permission: :view_live_feed
          },
          %{
            label: gettext("Leaderboard"),
            path: base <> "/leaderboard",
            feature: :stats,
            icon: "hero-trophy",
            permission: :view_stats
          },
          %{
            label: gettext("Matches"),
            path: base <> "/matches",
            feature: :stats,
            icon: "hero-flag",
            permission: :view_stats
          },
          %{
            label: gettext("Tickets"),
            path: base <> "/tickets",
            feature: :tickets,
            icon: "hero-chat-bubble-left-ellipsis",
            permission: :view_tickets,
            badge: waiting_tickets(nav, id)
          }
        ]
      },
      %{
        title: gettext("Automation"),
        items: [
          %{
            label: gettext("Rules"),
            path: base <> "/rules",
            feature: :rules,
            icon: "hero-bolt",
            permission: :view_rules
          },
          %{
            label: gettext("History"),
            path: base <> "/history",
            feature: :rules,
            icon: "hero-clock",
            permission: :view_executions
          },
          %{
            label: gettext("Attention"),
            path: base <> "/attention",
            icon: "hero-bell-alert",
            permission: :view_executions
          }
        ]
      },
      %{
        title: gettext("Community"),
        items: [
          %{
            label: gettext("Achievements"),
            path: base <> "/achievements",
            feature: :progression,
            icon: "hero-trophy",
            permission: :view_progression
          },
          %{
            label: gettext("Seasons"),
            path: base <> "/seasons",
            feature: :progression,
            icon: "hero-calendar-days",
            permission: :view_progression
          }
        ]
      },
      %{
        title: gettext("Settings"),
        items: [
          %{
            label: gettext("Marketplace"),
            path: base <> "/marketplace",
            icon: "hero-squares-plus",
            permission: :manage_servers
          },
          %{
            label: gettext("Server settings"),
            path: base <> "/edit",
            icon: "hero-cog-6-tooth",
            permission: :manage_servers
          }
        ]
      }
    ]
    |> visible_sections(current_user, nav)
  end

  defp nav_sections(current_user, nav) do
    [
      %{
        title: gettext("Organisation"),
        items: [
          %{label: gettext("Overview"), path: "/", icon: "hero-squares-2x2", permission: nil},
          %{
            label: gettext("Attention"),
            path: "/attention",
            icon: "hero-bell-alert",
            permission: :view_executions
          },
          %{
            label: gettext("Tickets"),
            path: "/tickets",
            feature: :tickets,
            icon: "hero-chat-bubble-left-ellipsis",
            permission: :view_tickets,
            badge: waiting_tickets(nav)
          },
          %{
            label: gettext("Servers"),
            path: "/servers",
            icon: "hero-server-stack",
            permission: :view_servers
          }
        ]
      },
      %{
        title: gettext("Automation"),
        items: [
          %{
            label: gettext("All rules"),
            path: "/rules",
            feature: :rules,
            icon: "hero-bolt",
            permission: :view_rules
          },
          %{
            label: gettext("Discord"),
            path: "/discord",
            icon: "hero-chat-bubble-left-right",
            permission: :manage_integrations
          },
          %{
            label: gettext("History"),
            path: "/executions",
            feature: :rules,
            icon: "hero-clock",
            permission: :view_executions
          },
          %{
            label: gettext("Metrics"),
            path: "/metrics",
            icon: "hero-chart-bar",
            permission: :view_executions
          }
        ]
      },
      %{
        title: gettext("Community"),
        items: [
          %{
            label: gettext("Seasons"),
            path: "/seasons",
            feature: :progression,
            icon: "hero-calendar-days",
            permission: :view_progression
          }
        ]
      },
      %{
        title: gettext("Platform"),
        items: [
          %{
            label: gettext("Users"),
            path: "/users",
            icon: "hero-users",
            permission: :manage_users
          },
          %{
            label: gettext("Roles"),
            path: "/roles",
            icon: "hero-shield-check",
            permission: :manage_roles
          }
        ]
      }
    ]
    |> visible_sections(current_user, nav)
  end

  # Tickets waiting on an admin, for the badge next to "Tickets".
  defp waiting_tickets(%{tickets: counts}) when is_map(counts),
    do: counts |> Map.values() |> Enum.sum()

  defp waiting_tickets(_nav), do: 0

  defp waiting_tickets(%{tickets: counts}, server_id) when is_map(counts),
    do: Map.get(counts, server_id, 0)

  defp waiting_tickets(_nav, _server_id), do: 0

  # Entries the role cannot reach are dropped, and a section left with
  # nothing in it disappears too.
  defp visible_sections(sections, current_user, nav) do
    sections
    |> Enum.map(fn section ->
      items =
        Enum.filter(
          section.items,
          &(allowed?(current_user, &1.permission) and Nav.feature?(nav, &1[:feature]))
        )

      %{section | items: items}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  # ── Scope switcher ─────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :nav, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_path, :string, required: true

  # The card at the top of the sidebar that says where you are - a server,
  # with its game, stream and link to switch, or the whole organisation - the
  # way CRCON's own sidebar opens on the server it belongs to. Switching keeps
  # the page: from one server's leaderboard to the other's.
  defp scope_switcher(assigns) do
    ~H"""
    <div class="relative shrink-0 border-b border-base-300 p-3" x-data="{ open: false }">
      <button
        type="button"
        id={"#{@id}-button"}
        class="scope-switcher"
        x-on:click="open = !open"
        x-bind:aria-expanded="open"
        aria-haspopup="menu"
        aria-controls={"#{@id}-menu"}
      >
        <%= if @nav.server do %>
          <img
            src={server_art(@nav.server)}
            alt=""
            class="size-9 shrink-0 rounded-field object-cover"
          />
          <span class="min-w-0 flex-1 text-left">
            <span class="block truncate text-sm font-medium leading-tight">
              {@nav.server.name}
            </span>

            <span class="flex items-center gap-1.5 text-xs text-muted">
              <span class={["size-1.5 shrink-0 rounded-full", stream_dot(@nav.status)]}></span>
              <span class="truncate">
                {Labels.game(@nav.server.game)} · {Labels.stream_status(@nav.status)}
              </span>
            </span>
          </span>
        <% else %>
          <span class="flex size-9 shrink-0 items-center justify-center rounded-field bg-base-content text-base-100">
            <.icon name="hero-squares-2x2" class="size-4" />
          </span>

          <span class="min-w-0 flex-1 text-left">
            <span class="block truncate text-sm font-medium leading-tight">
              {gettext("All servers")}
            </span>

            <span class="block truncate text-xs text-muted">
              {ngettext("1 server", "%{count} servers", length(@nav.servers))}
            </span>
          </span>
        <% end %>
        <.icon name="hero-chevron-up-down" class="size-4 shrink-0 text-muted" />
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
        <p class="px-2 pt-1 pb-1.5 text-[0.6875rem] font-medium tracking-wide text-muted uppercase">
          {gettext("Servers")}
        </p>

        <.link
          :for={server <- @nav.servers}
          navigate={Nav.switch_path(@current_path, server.id)}
          role="menuitem"
          class={["scope-menu-item", @nav.server && @nav.server.id == server.id && "is-current"]}
        >
          <img src={server_art(server)} alt="" class="size-7 shrink-0 rounded-selector object-cover" />
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

        <div class="my-1 h-px bg-base-300"></div>

        <.link
          navigate={~p"/"}
          role="menuitem"
          class={["scope-menu-item", is_nil(@nav.server) && "is-current"]}
        >
          <span class="flex size-7 shrink-0 items-center justify-center rounded-selector bg-base-200">
            <.icon name="hero-squares-2x2" class="size-4 text-subtle" />
          </span>
          <span class="flex-1 text-sm">{gettext("All servers")}</span>
        </.link>

        <.link
          :if={Accounts.can?(@current_user, :manage_servers)}
          navigate={~p"/servers/new"}
          role="menuitem"
          class="scope-menu-item"
        >
          <span class="flex size-7 shrink-0 items-center justify-center rounded-selector bg-base-200">
            <.icon name="hero-plus" class="size-4 text-subtle" />
          </span>
          <span class="flex-1 text-sm">{gettext("Add a server")}</span>
        </.link>
      </div>
    </div>
    """
  end

  defp stream_dot(:connected), do: "bg-success"
  defp stream_dot(:connecting), do: "bg-warning"
  defp stream_dot({:error, _reason}), do: "bg-error"
  defp stream_dot(_status), do: "bg-base-300"

  defp allowed?(_user, nil), do: true
  defp allowed?(user, permission), do: Accounts.can?(user, permission)

  defp active?(current_path, "/"), do: current_path == "/"

  defp active?(current_path, "/servers/" <> rest = path) do
    if String.contains?(rest, "/"),
      do: String.starts_with?(current_path, path),
      else: current_path == path or String.starts_with?(current_path, path <> "/edit")
  end

  defp active?(current_path, "/servers"),
    do: current_path == "/servers" or current_path == "/servers/new"

  defp active?(current_path, path), do: String.starts_with?(current_path, path)

  defp role_name(%{role: %{name: name}}), do: name
  defp role_name(_user), do: nil

  defp initials(%{name: name}) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initials(%{username: username}), do: username |> String.first() |> String.upcase()
  defp initials(_user), do: "?"
end
