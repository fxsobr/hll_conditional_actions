defmodule HllConditionalActionsWeb.ShopComponents do
  @moduledoc """
  The public VIP shop's frame and pieces.

  Everything paints with the theme's custom properties (`--sh-*`, see
  `assets/css/areas/shop.css`), set by the theme the admin picked in
  `HllConditionalActions.VipShop.Design`; an admin's own accent colour is
  applied inline over it. Nothing here hard-codes a colour of its own.

  The home page is the hero followed by the sections the admin enabled, in
  their order: benefits, packages, servers, questions and a closing call.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Design, Package}
  alias HllConditionalActionsWeb.ShopFormat

  # ── Theme ──────────────────────────────────────────────────────────────────

  @doc "The classes that set a design's theme on a wrapper."
  @spec theme_class(map()) :: String.t()
  def theme_class(design), do: "shop shop-theme-#{theme_name(design)}"

  defp theme_name(design) do
    if design["theme"] in Design.themes(), do: design["theme"], else: "tactical"
  end

  @doc "The inline style of an admin's own accent colour, or nil."
  @spec theme_style(map()) :: String.t() | nil
  def theme_style(%{"accent" => "#" <> _hex = accent}) do
    on = Design.on_color(accent)

    Enum.map_join(
      [
        {"accent", accent},
        {"on-accent", on},
        {"accent-fill", accent},
        {"highlight", accent},
        {"accent-text", accent},
        {"link", accent},
        {"img-accent", accent},
        {"accent-soft", "color-mix(in oklab, #{accent} 16%, transparent)"},
        {"accent-tile", "color-mix(in oklab, #{accent} 12%, transparent)"}
      ],
      "; ",
      fn {name, value} -> "--sh-#{name}: #{value}" end
    )
  end

  def theme_style(_design), do: nil

  @dev_preview Application.compile_env(:hll_conditional_actions, :dev_routes, false)

  @doc """
  In development only: `?theme=<name>` shows the shop in another theme (with its own accent) and
  `?sections=all` turns every section on, without saving anything - to
  compare the storefront with the design boards. Elsewhere the settings are
  returned as they are.
  """
  @spec preview_settings(map(), map()) :: map()
  def preview_settings(settings, params) when @dev_preview and is_map(params) do
    design = settings.design || %{}

    design =
      if params["theme"] in Design.themes(),
        do: design |> Map.put("theme", params["theme"]) |> Map.put("accent", nil),
        else: design

    design =
      if params["sections"] == "all",
        do:
          Map.put(
            design,
            "sections",
            Enum.map(Design.section_keys(), &%{"key" => &1, "enabled" => true})
          ),
        else: design

    %{settings | design: design}
  end

  def preview_settings(settings, _params), do: settings

  # ── Frame ──────────────────────────────────────────────────────────────────

  attr :settings, :map, required: true
  attr :current_customer, :map, default: nil
  attr :flash, :map, default: %{}
  attr :current_path, :string, default: "/shop"
  attr :nav, :boolean, default: true, doc: "the section links of the storefront"
  attr :footer, :boolean, default: true
  attr :menu, :boolean, default: true, doc: "the phone's menu button"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "The storefront's frame: the header, the page and the footer."
  def shell(assigns) do
    assigns = assign(assigns, :design, Design.get(assigns.settings.design))

    ~H"""
    <div
      id="shop"
      class={[theme_class(@design), "flex min-h-dvh flex-col antialiased", @class]}
      style={theme_style(@design)}
    >
      <.shop_header
        settings={@settings}
        design={@design}
        current_customer={@current_customer}
        current_path={@current_path}
        nav={@nav}
        menu={@menu}
      />
      <.shop_flash flash={@flash} />
      <main class="mx-auto flex w-full max-w-[90rem] flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>
      <.shop_footer :if={@footer} settings={@settings} />
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :design, :map, required: true
  attr :current_customer, :map, default: nil
  attr :current_path, :string, required: true
  attr :nav, :boolean, default: true
  attr :menu, :boolean, default: true

  defp shop_header(assigns) do
    ~H"""
    <header class="mx-auto flex h-20 w-full max-w-[90rem] shrink-0 items-center gap-2.5 px-4 sm:h-[4.75rem] sm:gap-10 sm:px-8 lg:px-12">
      <.brand settings={@settings} class="min-w-0 flex-1 sm:flex-none" />
      <nav
        :if={@nav}
        aria-label={gettext("Shop sections")}
        class="hidden items-center gap-1.5 text-sm font-medium md:flex"
      >
        <.link
          :for={{href, label} <- section_links()}
          href={href}
          class="shop-nav-link flex h-10 items-center px-4"
        >
          {label}
        </.link>
      </nav>
      <span class="hidden grow sm:block"></span>
      <%= if @current_customer do %>
        <.link
          navigate={~p"/shop/account"}
          id="shop-account-link"
          class="shop-btn shop-btn-quiet h-11 gap-2.5 !font-medium pl-[5px] pr-[5px] text-sm sm:pr-[18px]"
          aria-label={gettext("My account")}
        >
          <.initials_tile
            name={customer_name(@current_customer)}
            class="size-[2.125rem] text-xs"
            round
          />
          <span class="hidden sm:inline">{gettext("My account")}</span>
        </.link>
      <% else %>
        <.link
          navigate={~p"/shop/login"}
          id="shop-sign-in"
          class="shop-btn shop-btn-quiet h-11 gap-2 !font-medium px-4 text-sm sm:pl-4 sm:pr-5"
        >
          <.icon name="hero-user" class="hidden size-[18px] sm:block" />{gettext("Sign in")}
        </.link>
      <% end %>
      <details :if={@nav and @menu} class="group relative md:hidden">
        <summary
          class="shop-btn shop-btn-quiet size-11 list-none [&::-webkit-details-marker]:hidden"
          aria-label={gettext("Menu")}
        >
          <.icon name="hero-bars-3" class="size-5 group-open:hidden" />
          <.icon name="hero-x-mark" class="hidden size-5 group-open:block" />
        </summary>
        <nav
          aria-label={gettext("Shop sections")}
          class="shop-panel absolute right-0 z-40 mt-2 flex w-56 flex-col gap-1 rounded-2xl p-2 shadow-xl"
        >
          <.link
            :for={{href, label} <- section_links()}
            href={href}
            class="shop-nav-link flex h-11 items-center px-4 text-sm font-medium"
          >
            {label}
          </.link>
          <.locale_switch current_path={@current_path} class="mt-1 self-start" />
        </nav>
      </details>
    </header>
    """
  end

  defp section_links do
    [
      {"/shop#pacotes", gettext("Packages")},
      {"/shop#servidores", gettext("Servers")},
      {"/shop#duvidas", gettext("Questions")}
    ]
  end

  attr :settings, :map, required: true
  attr :class, :any, default: nil
  attr :size, :string, default: "md", values: ~w(md lg)
  attr :on_image, :boolean, default: false

  @doc "The shop's logo tile, name and \"Loja VIP\"."
  def brand(assigns) do
    ~H"""
    <.link navigate={~p"/shop"} class={["flex items-center gap-2.5 sm:gap-3", @class]}>
      <span class={[
        "flex shrink-0 items-center justify-center overflow-hidden",
        if(@on_image,
          do: "shop-glass size-12 rounded-2xl",
          else: "shop-logo size-[2.625rem] sm:size-11"
        )
      ]}>
        <img
          :if={@settings.logo_asset_id}
          src={~p"/shop/assets/#{@settings.logo_asset_id}"}
          alt=""
          class="size-full object-cover"
        />
        <.shield_mark
          :if={!@settings.logo_asset_id}
          class={if(@on_image, do: "size-6 text-[var(--sh-img-accent)]", else: "size-6")}
        />
      </span>
      <span class="flex min-w-0 flex-col">
        <strong class="truncate font-display text-[1.0625rem] font-bold tracking-[-0.01em] sm:text-lg">
          {shop_name(@settings)}
        </strong>
        <span class={[
          "shop-stencil truncate text-xs",
          if(@on_image,
            do: "text-[0.8125rem] text-[var(--sh-img-text-2)]",
            else: "text-[var(--sh-text-3)]"
          )
        ]}>
          {gettext("VIP shop")}
        </span>
      </span>
    </.link>
    """
  end

  attr :class, :any, default: "size-6"

  @doc "The shield with a star the board uses when the shop has no logo."
  def shield_mark(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M12 2.5 19.5 5.5v6c0 4.7-3.2 8.4-7.5 9.9-4.3-1.5-7.5-5.2-7.5-9.9v-6L12 2.5z" />
      <path
        d="m12 7.8 1.3 2.7 3 .4-2.2 2.1.5 3L12 14.6 9.4 16l.5-3-2.2-2.1 3-.4L12 7.8z"
        fill="currentColor"
      />
    </svg>
    """
  end

  attr :settings, :map, required: true

  defp shop_footer(assigns) do
    ~H"""
    <footer class="mx-auto flex w-full max-w-[90rem] flex-wrap items-center gap-x-5 gap-y-2 px-4 py-8 text-[0.8125rem] text-[var(--sh-text-3)] sm:px-8 lg:px-12">
      <span>© {Date.utc_today().year} {shop_name(@settings)}</span>
      <a
        :for={{network, url} <- social_links(@settings)}
        href={url}
        target="_blank"
        rel="noopener noreferrer"
        class="text-[var(--sh-text-2)] transition hover:text-[var(--sh-text)]"
      >
        {Labels.social_network(network)}
      </a>
      <span class="hidden grow sm:block"></span>
      <.made_with />
    </footer>
    """
  end

  @doc "\"Loja feita com Ações Condicionais\"."
  def made_with(assigns) do
    ~H"""
    <span class="flex items-center gap-2 text-xs text-[var(--sh-text-3)]">
      <svg
        class="size-3.5"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m5 11 7-5 7 5" /><path d="m5 17 7-5 7 5" />
      </svg>
      {gettext("Shop made with Conditional Actions")}
    </span>
    """
  end

  attr :flash, :map, required: true

  defp shop_flash(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-[90rem] px-4 empty:hidden sm:px-8 lg:px-12">
      <.flash_line
        :for={{kind, text} <- flash_messages(@flash)}
        kind={kind}
        text={text}
        class="mb-4"
      />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :text, :string, required: true
  attr :class, :any, default: nil

  @doc "One flash message in the shop's colours."
  def flash_line(assigns) do
    ~H"""
    <p
      id={"shop-flash-#{@kind}"}
      role={if @kind == :error, do: "alert", else: "status"}
      class={[
        "flex items-start gap-3 rounded-2xl px-4 py-3 text-sm",
        if(@kind == :error,
          do: "bg-[color-mix(in_oklab,var(--sh-danger)_14%,transparent)] text-[var(--sh-text)]",
          else: "shop-raised text-[var(--sh-text)]"
        ),
        @class
      ]}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-check-circle"}
        class={[
          "mt-0.5 size-4 shrink-0",
          if(@kind == :error, do: "text-[var(--sh-danger)]", else: "text-[var(--sh-accent)]")
        ]}
      />
      <span>{@text}</span>
    </p>
    """
  end

  @doc "The info and error flash messages that are set."
  def flash_messages(flash) do
    for kind <- [:info, :error], text = Phoenix.Flash.get(flash, kind), do: {kind, text}
  end

  # ── Small pieces ───────────────────────────────────────────────────────────

  attr :name, :string, required: true
  attr :class, :any, default: "size-9 text-xs"
  attr :round, :boolean, default: false
  attr :tone, :string, default: "person", values: ~w(person muted)

  @doc "A player's or customer's initials in a tile."
  def initials_tile(assigns) do
    ~H"""
    <span class={[
      "flex shrink-0 items-center justify-center font-bold",
      if(@round, do: "rounded-full", else: "rounded-xl"),
      if(@tone == "person",
        do: "shop-pill-person",
        else: "shop-raised text-[var(--sh-text-2)]"
      ),
      @class
    ]}>
      {ShopFormat.initials(@name)}
    </span>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :class, :any, default: nil

  @doc "The round back button beside a page title."
  def back_button(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-label={@label}
      class={["shop-btn shop-btn-quiet size-11 shrink-0", @class]}
    >
      <.icon name="hero-chevron-left" class="size-[18px]" />
    </.link>
    """
  end

  attr :step, :integer, required: true, doc: "1 player, 2 payment, 3 done"
  attr :class, :any, default: nil

  @doc "The three steps of a purchase: Jogador, Pagamento, Pronto."
  def stepper(assigns) do
    assigns =
      assign(assigns, :steps, [
        {1, gettext("Player")},
        {2, gettext("Payment")},
        {3, gettext("Ready")}
      ])

    ~H"""
    <ol
      aria-label={gettext("Steps")}
      class={["flex items-center gap-3 text-[0.8125rem] text-[var(--sh-text-3)]", @class]}
    >
      <%= for {n, label} <- @steps do %>
        <li :if={n > 1} aria-hidden="true" class="h-px w-8 bg-[var(--sh-step)]"></li>
        <li
          aria-current={if n == @step, do: "step"}
          class={[
            "flex items-center gap-2",
            n < @step && "font-semibold text-[var(--sh-text)]",
            n == @step && "font-semibold text-[var(--sh-accent-text)]"
          ]}
        >
          <span class={[
            "flex size-[1.625rem] items-center justify-center rounded-full text-xs",
            n < @step && "shop-pill-accent",
            n == @step && "bg-[var(--sh-accent)] text-[var(--sh-on-accent)]",
            n > @step && "border border-[var(--sh-step)]"
          ]}>
            <.icon :if={n < @step} name="hero-check" class="size-3.5" />
            <span :if={n >= @step}>{n}</span>
          </span>
          {label}
        </li>
      <% end %>
    </ol>
    """
  end

  attr :current_path, :string, required: true
  attr :class, :any, default: nil

  @doc "The PT · EN · ES switch."
  def locale_switch(assigns) do
    assigns =
      assigns
      |> assign(:current, Gettext.get_locale(HllConditionalActionsWeb.Gettext))
      |> assign(
        :locales,
        HllConditionalActionsWeb.Plugs.Locale.supported() |> Enum.sort_by(&locale_order/1)
      )

    ~H"""
    <div
      :if={length(@locales) > 1}
      role="group"
      aria-label={gettext("Language")}
      class={["shop-raised flex gap-1 rounded-full p-1", @class]}
    >
      <a
        :for={locale <- @locales}
        href={"/locale/#{locale}?" <> URI.encode_query(return_to: @current_path)}
        aria-current={if locale == @current, do: "true"}
        class={[
          "flex h-8 items-center rounded-full px-3 text-xs transition",
          if(locale == @current,
            do: "bg-[var(--sh-text)] font-semibold text-[var(--sh-ground)]",
            else: "text-[var(--sh-text-2)] hover:text-[var(--sh-text)]"
          )
        ]}
      >
        {locale |> String.split("_") |> List.first() |> String.upcase()}
      </a>
    </div>
    """
  end

  defp locale_order("pt_BR"), do: 0
  defp locale_order("en"), do: 1
  defp locale_order("es"), do: 2
  defp locale_order(_other), do: 3

  # ── Auth screens ───────────────────────────────────────────────────────────

  attr :settings, :map, required: true
  attr :flash, :map, default: %{}
  attr :current_path, :string, default: "/shop/login"
  attr :title, :string, required: true, doc: "the big headline over the picture"
  attr :lead, :string, default: nil
  attr :picture, :map, required: true, doc: "%{src, caption} of the side picture"
  attr :back, :map, default: nil, doc: "%{href, label} of the back link"
  attr :width, :string, default: "narrow", values: ~w(narrow wide)
  slot :inner_block, required: true
  slot :aside, doc: "under the headline, over the picture"

  @doc """
  The sign in, sign up and password screens: a picture with the shop's
  headline on one side, the form on a panel on the other. On phones only
  the panel shows.
  """
  def auth_layout(assigns) do
    design = Design.get(assigns.settings.design)
    assigns = assigns |> assign(:design, design) |> assign(:image_side, design["auth"]["side"])

    ~H"""
    <div
      id="shop"
      class={[
        theme_class(@design),
        "grid min-h-dvh gap-4 p-0 antialiased sm:p-4",
        if(@image_side == "right",
          do: "lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]",
          else: "lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]"
        )
      ]}
      style={theme_style(@design)}
    >
      <section class={[
        "shop-art shop-hero relative hidden lg:block",
        @image_side == "right" && "lg:order-last"
      ]}>
        <img src={@picture.src} alt="" class="shop-art-img" />
        <div
          class="absolute inset-0 z-[-1] bg-[linear-gradient(180deg,color-mix(in_oklab,var(--sh-img-bg)_60%,transparent)_0%,color-mix(in_oklab,var(--sh-img-bg)_15%,transparent)_30%,color-mix(in_oklab,var(--sh-img-bg)_82%,transparent)_62%,color-mix(in_oklab,var(--sh-img-bg)_95%,transparent)_100%)]"
          aria-hidden="true"
        >
        </div>
        <div class="relative flex h-full flex-col px-11 py-10">
          <.brand settings={@settings} on_image class="self-start" />
          <span class="grow"></span>
          <h1 class="max-w-[38.75rem] text-balance font-display text-[4.25rem] font-bold leading-[0.96] tracking-[-0.04em]">
            {@title}
          </h1>
          <p
            :if={@lead}
            class="mt-5 max-w-[33.75rem] text-lg leading-normal text-[var(--sh-img-text-2)]"
          >
            {@lead}
          </p>
          {render_slot(@aside)}
          <span :if={@picture.caption} class="mt-9 text-xs text-[var(--sh-img-text-3)]">
            {@picture.caption}
          </span>
        </div>
      </section>

      <section class="shop-panel flex min-h-dvh flex-col px-5 py-6 sm:min-h-0 sm:rounded-[2rem] sm:px-14 sm:py-10">
        <div class="flex items-center justify-between gap-3">
          <.brand settings={@settings} class="lg:hidden" />
          <.link
            :if={@back}
            navigate={@back.href}
            class="shop-btn shop-btn-secondary hidden h-10 gap-1.5 !font-normal pl-2.5 pr-4 text-[0.8125rem] lg:inline-flex"
          >
            <.icon name="hero-chevron-left" class="size-4" />{@back.label}
          </.link>
          <.locale_switch current_path={@current_path} />
        </div>
        <span class="grow"></span>
        <div class={[
          "mx-auto flex w-full flex-col gap-5 py-8",
          if(@width == "wide", do: "max-w-[32.5rem]", else: "max-w-[26.25rem]")
        ]}>
          <.flash_line :for={{kind, text} <- flash_messages(@flash)} kind={kind} text={text} />
          {render_slot(@inner_block)}
        </div>
        <span class="grow"></span>
        <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-[var(--sh-text-3)]">
          <span>© {Date.utc_today().year} {shop_name(@settings)}</span>
          <.made_with />
        </div>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :lead, :string, default: nil
  attr :size, :string, default: "lg", values: ~w(lg md)

  @doc "The heading of a sign in or sign up form."
  def auth_heading(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5">
      <h2 class={[
        "font-display font-semibold leading-[1.05] tracking-[-0.03em]",
        if(@size == "lg", do: "text-[2.25rem] sm:text-[2.625rem]", else: "text-[2.125rem]")
      ]}>
        {@title}
      </h2>
      <p :if={@lead} class="text-[0.9375rem] leading-normal text-[var(--sh-text-2)]">{@lead}</p>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :state, :string, default: nil, doc: "ok to mark the field as right"
  attr :class, :any, default: "h-[3.25rem]"
  attr :rest, :global, include: ~w(autocomplete required placeholder maxlength phx-debounce)
  slot :hint, doc: "under the field, when it has no error"
  slot :corner, doc: "on the label's line, at the right"

  @doc "A form field in the shop's colours, with a show/hide eye for passwords."
  def shop_input(assigns) do
    assigns =
      assign(
        assigns,
        :errors,
        if(Phoenix.Component.used_input?(assigns.field),
          do: Enum.map(assigns.field.errors, &translate_error/1),
          else: []
        )
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-baseline justify-between gap-3 text-[0.8125rem] font-medium text-[var(--sh-text-2)]">
        <label for={@field.id}>{@label}</label>
        {render_slot(@corner)}
      </div>
      <div class={[
        "shop-field pr-2 pl-[1.125rem]",
        @class,
        @errors != [] && "is-error",
        @errors == [] && @state == "ok" && "is-ok"
      ]}>
        <input
          type={@type}
          id={@field.id}
          name={@field.name}
          value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
          class="h-full text-[0.9375rem]"
          {@rest}
        />
        <button
          :if={@type == "password"}
          type="button"
          phx-click={JS.toggle_attribute({"type", "password", "text"}, to: "##{@field.id}")}
          aria-label={gettext("Show password")}
          class="flex size-10 shrink-0 items-center justify-center rounded-xl text-[var(--sh-text-3)] transition hover:text-[var(--sh-text)]"
        >
          <.icon name="hero-eye" class="size-[18px]" />
        </button>
        <.icon
          :if={@type != "password" and @errors == [] and @state == "ok"}
          name="hero-check"
          class="mr-2 size-[18px] text-[var(--sh-accent)]"
        />
      </div>
      <p :for={error <- @errors} class="text-xs text-[var(--sh-danger)]">{error}</p>
      <div :if={@errors == [] and @hint != []} class="text-xs leading-[1.45] text-[var(--sh-text-3)]">
        {render_slot(@hint)}
      </div>
    </div>
    """
  end

  attr :password, :string, default: ""
  attr :min, :integer, default: 8
  attr :id, :string, required: true
  attr :compact, :boolean, default: false

  @doc """
  How strong a password looks, in four bars: by length and by how many kinds
  of character it mixes.
  """
  def strength_meter(assigns) do
    score = password_score(assigns.password || "", assigns.min)
    length = String.length(assigns.password || "")

    assigns =
      assign(assigns,
        score: score,
        length: length,
        label: strength_label(score),
        tone: strength_tone(score)
      )

    ~H"""
    <div :if={@length > 0} id={@id} class="flex flex-col gap-1.5">
      <div class="flex items-center gap-2.5">
        <span
          role="meter"
          aria-label={gettext("Password strength")}
          aria-valuemin="0"
          aria-valuemax="4"
          aria-valuenow={@score}
          class="grid grow grid-cols-4 gap-1"
        >
          <span :for={n <- 1..4} class={["shop-meter", n <= @score && @tone]}></span>
        </span>
        <span class={[
          "text-xs font-semibold",
          if(@score >= 3, do: "text-[var(--sh-accent-text)]", else: "text-[var(--sh-warn)]")
        ]}>
          {@label}
        </span>
        <span :if={@compact} class="text-xs text-[var(--sh-text-3)]">
          {ngettext("%{count} character", "%{count} characters", @length)} · {gettext(
            "minimum %{count}",
            count: @min
          )}
        </span>
      </div>
      <span :if={!@compact} class="text-xs leading-[1.45] text-[var(--sh-text-3)]">
        {ngettext("%{count} character.", "%{count} characters.", @length)} {gettext(
          "Long phrases are easy to remember and hard to guess."
        )} {gettext("Minimum %{count}.", count: @min)}
      </span>
    </div>
    """
  end

  @doc false
  def password_score(password, min) do
    length = String.length(password)

    kinds =
      Enum.count(
        [~r/[a-z]/, ~r/[A-Z]/, ~r/[0-9]/, ~r/[^a-zA-Z0-9]/],
        &Regex.match?(&1, password)
      )

    cond do
      length == 0 -> 0
      length < min -> 1
      length < 12 -> if(kinds >= 3, do: 3, else: 2)
      length < 16 -> if(kinds >= 2, do: 4, else: 3)
      true -> 4
    end
  end

  defp strength_label(1), do: gettext("Too short")
  defp strength_label(2), do: gettext("Fair")
  defp strength_label(3), do: gettext("Good")
  defp strength_label(4), do: gettext("Strong")
  defp strength_label(_score), do: ""

  defp strength_tone(1), do: "is-weak"
  defp strength_tone(2), do: "is-fair"
  defp strength_tone(_score), do: "is-on"

  attr :label, :string, required: true
  attr :id, :string, default: "discord-login"

  @doc "The Continue with Discord button."
  def discord_button(assigns) do
    ~H"""
    <a
      href={~p"/shop/auth/discord"}
      id={@id}
      class="shop-btn shop-btn-accent h-14 shrink-0 gap-3 text-base"
    >
      <HllConditionalActionsWeb.BrandIcons.brand_icon name="discord" class="size-5" />
      {@label}
    </a>
    """
  end

  @doc "The divider between Discord and the email form."
  def or_divider(assigns) do
    ~H"""
    <div class="flex items-center gap-3.5 text-[0.8125rem] text-[var(--sh-text-3)]">
      <span class="h-px grow bg-[var(--sh-border)]"></span>{gettext("or with email")}<span class="h-px grow bg-[var(--sh-border)]"></span>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "A quiet note with an icon, on the raised surface."
  def note(assigns) do
    ~H"""
    <div class={[
      "shop-raised flex items-start gap-3 rounded-2xl px-4 py-3.5 text-[0.8125rem] leading-normal text-[var(--sh-text-2)]",
      @class
    ]}>
      <.icon name={@icon} class="mt-0.5 size-[18px] shrink-0 text-[var(--sh-accent)]" />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  # ── Home: hero ─────────────────────────────────────────────────────────────

  attr :settings, :map, required: true
  attr :design, :map, required: true
  attr :packages, :list, required: true
  attr :servers, :list, required: true
  attr :live, :list, required: true, doc: "the servers with their live state"
  attr :featured, :map, default: nil
  attr :methods, :list, default: []
  attr :zone, :string, default: "Etc/UTC"

  @doc "The top of the storefront: the picture, the promise and the busiest server now."
  def hero(assigns) do
    art = hero_art(assigns.settings, assigns.featured, assigns.live)

    assigns =
      assigns
      |> assign(:art, art)
      |> assign(:cheapest, Enum.min_by(assigns.packages, & &1.price_cents, fn -> nil end))

    ~H"""
    <section
      id="shop-hero"
      aria-label={shop_name(@settings)}
      class="shop-art shop-hero relative mx-4 h-[20.75rem] shrink-0 !rounded-[1.625rem] sm:h-[30rem] sm:!rounded-[var(--sh-r-hero)]"
    >
      <img src={@art.src} alt={@art.alt} class="shop-art-img" />
      <div class="shop-art-scrim hidden sm:block"></div>
      <div
        class="absolute inset-0 z-[-1] bg-[linear-gradient(180deg,color-mix(in_oklab,var(--sh-ground)_35%,transparent)_0%,color-mix(in_oklab,var(--sh-ground)_55%,transparent)_30%,color-mix(in_oklab,var(--sh-ground)_95%,transparent)_72%)] sm:hidden"
        aria-hidden="true"
      >
      </div>
      <span class="shop-hero-deco is-edge" aria-hidden="true"></span>
      <span class="shop-hero-deco is-corner is-tl hidden sm:block" aria-hidden="true"></span>
      <span class="shop-hero-deco is-corner is-tr hidden sm:block" aria-hidden="true"></span>
      <span class="shop-hero-deco is-corner is-bl hidden sm:block" aria-hidden="true"></span>
      <span
        :if={@art.caption}
        class="shop-caption shop-stencil absolute top-6 right-7 hidden text-xs sm:inline-flex [.shop-theme-desert_&]:right-[3.75rem]"
      >
        {@art.caption}
      </span>

      <div class="relative flex h-full flex-col justify-end gap-3 px-5 pt-4 pb-5 sm:gap-5 sm:px-16 sm:py-14">
        <%!-- Phone: the busiest server as one line at the top. --%>
        <span
          :if={@featured}
          class="shop-glass absolute top-4 left-5 flex h-[1.875rem] items-center gap-2 rounded-full !border-0 px-3 text-xs sm:hidden"
        >
          <span class="shop-live flex"><span class="shop-dot size-1.5"></span></span>
          {short_name(@featured.server)} · {players_line(@featured.live)}
          <span :if={queue(@featured) > 0} class="font-semibold text-[var(--sh-img-warn)]">
            · {queue_label(queue(@featured))}
          </span>
        </span>
        <span
          :if={@servers != []}
          class="shop-pill shop-img-pill shop-stencil hidden h-[1.875rem] items-center gap-2 self-start px-3 text-[0.8125rem] font-semibold sm:inline-flex"
        >
          <.icon name="hero-check" class="size-3.5" />{valid_on_label(@servers)}
        </span>
        <h1 class="max-w-[42.5rem] font-display text-[2.375rem] font-bold leading-[0.98] tracking-[-0.035em] text-balance sm:text-[4.75rem] sm:leading-[0.95] sm:tracking-[-0.04em]">
          {hero_title(@settings, @design)}
        </h1>
        <p class="max-w-[35rem] text-[0.9375rem] leading-normal text-[var(--sh-img-text-2)] sm:text-[1.1875rem]">
          {hero_text(@settings, @cheapest, @servers)}
        </p>
        <div class="mt-1 flex flex-col items-stretch gap-5 sm:mt-2 sm:flex-row sm:items-center">
          <a
            href="#pacotes"
            id="hero-cta"
            class="shop-btn shop-btn-accent h-[3.25rem] gap-2.5 text-base sm:h-14 sm:pr-[26px] sm:pl-7"
          >
            {@design["cta_label"] || gettext("See packages")}
            <.icon name="hero-arrow-down" class="size-[18px]" />
          </a>
          <span :if={@methods != []} class="hidden text-sm text-[var(--sh-img-text-2)] sm:inline">
            {methods_short(@methods)} · {gettext("in within minutes")}
          </span>
        </div>
      </div>

      <div
        :if={@featured}
        id="hero-live"
        class="shop-glass absolute right-7 bottom-7 hidden w-[18.75rem] flex-col gap-2.5 rounded-[1.25rem] px-[1.125rem] py-4 lg:flex [.shop-theme-desert_&]:rounded-[0.875rem]"
      >
        <div class="flex items-center justify-between">
          <span class="shop-live shop-live-label shop-stencil flex items-center gap-1.5 text-xs font-semibold">
            <span class="shop-dot size-[7px]"></span>
            {gettext("Now on %{server}", server: @featured.server.name)}
          </span>
          <span class="font-mono text-xs text-[var(--sh-img-text-3)]">
            {ShopFormat.time(@featured.live.read_at, @zone)}
          </span>
        </div>
        <div class="flex items-baseline gap-2.5">
          <span class="font-display text-[1.875rem] font-bold">
            {@featured.live.players}<span
              :if={@featured.live.max_players}
              class="text-base text-[var(--sh-img-text-3)]"
            >/{@featured.live.max_players}</span>
          </span>
          <span
            :if={queue(@featured) > 0}
            class="shop-pill shop-img-warn px-[9px] py-[3px] text-[0.8125rem] font-semibold"
          >
            {queue_label(queue(@featured))}
          </span>
        </div>
        <span class="text-[0.8125rem] text-[var(--sh-img-text-3)]">{featured_line(@featured)}</span>
      </div>
    </section>
    """
  end

  # The banner the admin uploaded, or the busiest server's map as it is
  # being played, with its name and time of day.
  defp hero_art(settings, featured, live) do
    cond do
      settings.banner_asset_id ->
        %{src: ~p"/shop/assets/#{settings.banner_asset_id}", alt: "", caption: nil}

      featured ->
        live_art(featured)

      live != [] ->
        live_art(hd(live))

      true ->
        %{src: "/images/hll/banner.webp", alt: "", caption: nil}
    end
  end

  @doc "A server's picture: the map being played, with its caption."
  def live_art(%{server: server, live: live}) do
    case live do
      %{layer: layer, map: map} when is_map(layer) ->
        caption = Enum.reject([map, ShopFormat.environment(live.environment)], &is_nil/1)

        %{
          src: HllConditionalActionsWeb.MapArt.url(Map.get(server, :game), layer),
          alt: map || "",
          caption: if(caption == [], do: nil, else: Enum.join(caption, " · "))
        }

      _unknown ->
        %{src: HllConditionalActionsWeb.Ui.server_art(server), alt: "", caption: nil}
    end
  end

  # The storefront's own headline, then the shop's subtitle; a field left
  # blank falls through to the next.
  defp hero_title(settings, design) do
    Enum.find(
      [get_in(design, ["titles", "hero"]), settings.shop_subtitle],
      gettext("Get to the front of the queue."),
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  defp hero_text(settings, cheapest, servers) do
    cond do
      settings.shop_description not in [nil, ""] ->
        settings.shop_description

      cheapest ->
        gettext(
          "VIP from %{price}: you skip the queue and get into %{shop}'s servers even when they are full.",
          price: VipShop.format_money(cheapest.price_cents, cheapest.currency),
          shop: shop_name(settings)
        )

      true ->
        ngettext(
          "Skip the queue and get into the server even when it is full.",
          "Skip the queue and get into the %{count} servers even when they are full.",
          length(servers)
        )
    end
  end

  defp featured_line(featured) do
    cond do
      queue(featured) > 0 -> gettext("With VIP you would be next in.")
      full?(featured.live) -> gettext("Full: with VIP you get the reserved slot.")
      true -> gettext("There is room: jump in now.")
    end
  end

  defp full?(%{players: players, max_players: max}) when is_integer(max), do: players >= max
  defp full?(_live), do: false

  defp queue(%{live: %{queue: queue}}) when is_integer(queue), do: queue
  defp queue(_server), do: 0

  defp queue_label(count), do: ngettext("%{count} in queue", "%{count} in queue", count)

  defp players_line(%{players: players, max_players: max}) when is_integer(max),
    do: "#{players}/#{max}"

  defp players_line(%{players: players}), do: to_string(players)

  @doc ~s("BR #1" from "BR #1 Público": the name up to its number.)
  def short_name(server) do
    case Regex.run(~r/^(.*?#\s*\d+)/u, server.name) do
      [_match, short] -> short
      _none -> server.name
    end
  end

  defp valid_on_label(servers) do
    ngettext("Valid on the server", "Valid on the %{count} servers", length(servers))
  end

  # ── Home: benefits ─────────────────────────────────────────────────────────

  attr :design, :map, required: true

  @doc "The three benefits: a panel of three on a computer, chips on a phone."
  def benefits(assigns) do
    assigns = assign(assigns, :items, benefit_items(assigns.design))

    ~H"""
    <section
      id="beneficios"
      aria-label={gettext("VIP benefits")}
      class="shop-panel mx-4 mt-5 hidden rounded-[1.75rem] px-3 py-7 sm:grid sm:grid-cols-2 lg:grid-cols-3 [.shop-theme-desert_&]:rounded-[1.25rem]"
    >
      <div
        :for={{item, index} <- Enum.with_index(@items)}
        class={[
          "shop-hairline flex gap-4 px-6 py-2 lg:py-0",
          index < length(@items) - 1 && "lg:border-r"
        ]}
      >
        <span class="shop-tile flex size-12 shrink-0 items-center justify-center">
          <.icon name={"hero-#{item["icon"]}"} class="size-[22px]" />
        </span>
        <span class="flex flex-col gap-1.5">
          <strong class="font-display text-[1.1875rem] font-semibold">{item["title"]}</strong>
          <span
            :if={item["text"] not in [nil, ""]}
            class="text-sm leading-normal text-[var(--sh-text-2)]"
          >
            {item["text"]}
          </span>
        </span>
      </div>
    </section>
    <ul
      aria-label={gettext("VIP benefits")}
      class="mx-4 mt-3 flex gap-1.5 overflow-x-auto sm:hidden"
    >
      <li
        :for={item <- @items}
        class="shop-panel flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full !border-0 px-[11px] text-xs"
      >
        <.icon name="hero-check" class="size-3 text-[var(--sh-accent)]" />{item["short"] ||
          item["title"]}
      </li>
    </ul>
    """
  end

  defp benefit_items(design) do
    case design["benefits"] do
      [_ | _] = items -> Enum.take(items, 3)
      _none -> default_benefits()
    end
  end

  # ── Home: packages ─────────────────────────────────────────────────────────

  attr :design, :map, required: true
  attr :settings, :map, required: true
  attr :packages, :list, required: true
  attr :servers, :list, required: true
  attr :methods, :list, default: []
  attr :coupons?, :boolean, default: false

  @doc "The packages on sale, the highlighted one first on a phone."
  def packages_section(assigns) do
    ~H"""
    <section
      id="pacotes"
      aria-labelledby="pacotes-titulo"
      class="flex scroll-mt-4 flex-col gap-2.5 px-4 pt-4 sm:gap-7 sm:px-8 sm:pt-20 lg:px-12"
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between sm:gap-6">
        <div class="flex flex-col gap-1 sm:gap-2.5">
          <span class="shop-eyebrow hidden text-xs tracking-[0.06em] text-[var(--sh-text-3)] uppercase sm:block">
            {gettext("Packages")}
          </span>
          <h2
            id="pacotes-titulo"
            class="font-display text-2xl font-semibold tracking-[-0.02em] sm:text-[2.75rem] sm:tracking-[-0.03em]"
          >
            {title(@design, "packages")}
          </h2>
          <p class="hidden text-base text-[var(--sh-text-2)] sm:block">
            {packages_subtitle(@design, @packages, @servers, @settings)}
          </p>
          <p class="text-[0.8125rem] text-[var(--sh-text-3)] sm:hidden">
            {packages_subtitle_short(@packages, @servers, @settings)}
          </p>
        </div>
        <div class="hidden flex-wrap gap-2 sm:flex">
          <span :if={@methods != []} class="shop-chip h-8 px-3 text-[0.8125rem]">
            {methods_long(@methods)}
          </span>
          <span :if={@coupons?} class="shop-chip h-8 px-3 text-[0.8125rem]">
            {gettext("Coupon at the next step")}
          </span>
        </div>
      </div>

      <p :if={@packages == []} class="py-10 text-[var(--sh-text-2)]">
        {gettext("No package is on sale right now.")}
      </p>

      <div class={[
        "grid gap-2.5 sm:gap-5",
        length(@packages) >= 3 && "sm:grid-cols-2 lg:grid-cols-3",
        length(@packages) == 2 && "sm:grid-cols-2",
        length(@packages) == 1 && "sm:max-w-md"
      ]}>
        <.package_card
          :for={package <- @packages}
          package={package}
          show_servers={@settings.show_servers}
        />
      </div>
    </section>
    """
  end

  attr :package, Package, required: true
  attr :show_servers, :boolean, default: true

  @doc "One package: its name, price, what it gives and the button to buy it."
  def package_card(assigns) do
    assigns =
      assigns
      |> assign(:highlight?, assigns.package.highlight not in [nil, ""])
      |> assign(:perks, perks(assigns.package, assigns.show_servers))

    ~H"""
    <article
      id={"package-#{@package.id}"}
      class={[
        "flex flex-col gap-1.5 px-5 py-[1.125rem] sm:p-7",
        if(@highlight?, do: "shop-highlight max-sm:order-first", else: "shop-card")
      ]}
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-display text-xl font-semibold sm:text-[1.375rem]">{@package.name}</h3>
        <%= if @highlight? do %>
          <span class="shop-pill shop-highlight-badge shop-stencil px-[9px] py-1 text-[0.6875rem] font-bold sm:px-2.5 sm:py-[5px] sm:text-xs">
            {@package.highlight}
          </span>
        <% else %>
          <span class="shop-stencil text-[0.8125rem] text-[var(--sh-text-2)]">
            {duration(@package.duration_days)}
          </span>
        <% end %>
      </div>
      <span class="mt-1.5 flex flex-wrap items-baseline gap-x-3 gap-y-1 sm:mt-3.5">
        <span class="font-display text-[2.375rem] leading-none font-bold tracking-[-0.02em] sm:text-[2.875rem]">
          {VipShop.format_money(@package.price_cents, @package.currency)}
        </span>
        <span
          :if={@package.compare_at_cents}
          class={[
            "text-sm line-through sm:text-[0.9375rem]",
            if(@highlight?, do: "shop-on-2", else: "text-[var(--sh-text-3)]")
          ]}
        >
          {gettext("was %{price}",
            price: VipShop.format_money(@package.compare_at_cents, @package.currency)
          )}
        </span>
      </span>
      <span class={[
        "text-[0.8125rem]",
        if(@highlight?, do: "shop-on-2", else: "text-[var(--sh-text-3)]")
      ]}>
        {package_line(@package)}
      </span>

      <div :if={@perks != []} class="shop-divider mt-[1.125rem] mb-3.5 hidden sm:block"></div>
      <ul :if={@perks != []} class="hidden flex-col gap-2.5 text-sm sm:flex">
        <li :for={perk <- @perks} class="flex items-center gap-2.5">
          <.icon
            name="hero-check"
            class={[
              "size-4 shrink-0",
              if(@highlight?, do: "text-[var(--sh-on-accent)]", else: "text-[var(--sh-accent)]")
            ]}
          />
          <span>{perk}</span>
        </li>
      </ul>
      <span class="hidden grow sm:block"></span>
      <.link
        navigate={~p"/shop/buy/#{@package.id}"}
        id={"buy-#{@package.id}"}
        class={[
          "shop-btn mt-1.5 h-12 text-[0.9375rem] sm:mt-5 sm:h-[3.25rem]",
          if(@highlight?, do: "shop-highlight-btn", else: "shop-btn-secondary")
        ]}
      >
        {gettext("Choose %{name}", name: short_package_name(@package))}
        <.icon :if={@highlight?} name="hero-arrow-right" class="size-[18px]" />
      </.link>
    </article>
    """
  end

  # "30 dias · R$ 16,63 por mês · economize R$ 9,80", from the package itself.
  defp package_line(%Package{} = package) do
    per_month =
      if is_integer(package.duration_days) and package.duration_days >= 60 do
        gettext("%{price} a month",
          price:
            VipShop.format_money(
              round(package.price_cents * 30 / package.duration_days),
              package.currency
            )
        )
      end

    savings =
      if is_integer(package.compare_at_cents) and package.compare_at_cents > package.price_cents do
        gettext("save %{amount}",
          amount:
            VipShop.format_money(package.compare_at_cents - package.price_cents, package.currency)
        )
      end

    lead =
      case package.duration_days do
        nil -> gettext("Yours for good")
        days when days in 365..366 -> gettext("A whole year")
        days when days <= 31 -> gettext("To try it out · renew whenever you like")
        days -> duration(days)
      end

    [lead, per_month, savings] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  # "VIP Trimestral" -> "Trimestral": the button already says what it is.
  defp short_package_name(%Package{name: name}) do
    case Regex.run(~r/^VIP\s+(.+)$/iu, name) do
      [_all, rest] -> rest
      _other -> name
    end
  end

  # Each line of the description is a perk; the servers close the list.
  defp perks(%Package{} = package, show_servers) do
    lines =
      (package.description || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    servers =
      if show_servers and package.servers != [],
        do: [ShopFormat.join(Enum.map(package.servers, &short_name/1))],
        else: []

    lines ++ servers
  end

  defp packages_subtitle(design, packages, servers, settings) do
    get_in(design, ["titles", "packages_subtitle"]) ||
      Enum.join(
        Enum.reject(
          [all_valid_line(packages, servers), stacking_line(settings)],
          &is_nil/1
        ),
        " "
      )
  end

  defp packages_subtitle_short(packages, servers, settings) do
    Enum.join(
      Enum.reject(
        [
          if(all_on_every_server?(packages, servers),
            do: ngettext("Valid on the server", "Valid on the %{count} servers", length(servers))
          ),
          if(settings.stacking == "extend", do: gettext("days add up"))
        ],
        &is_nil/1
      ),
      " · "
    )
  end

  defp all_valid_line(packages, servers) do
    if all_on_every_server?(packages, servers) and length(servers) > 1,
      do: gettext("All of them are valid on the %{count} servers.", count: length(servers))
  end

  defp all_on_every_server?(packages, servers) do
    ids = MapSet.new(servers, & &1.id)
    packages != [] and Enum.all?(packages, &(MapSet.new(&1.servers, fn s -> s.id end) == ids))
  end

  defp stacking_line(%{stacking: "extend"}),
    do: gettext("Already VIP? The new days add up to the ones you have left.")

  defp stacking_line(_settings), do: nil

  # ── Home: servers ──────────────────────────────────────────────────────────

  attr :design, :map, required: true
  attr :live, :list, required: true
  attr :read_at, :any, default: nil
  attr :now, :any, required: true

  @doc "Where the VIP counts, live: each server's map, players and queue."
  def servers_section(assigns) do
    ~H"""
    <section
      id="servidores"
      aria-labelledby="servidores-titulo"
      class="flex scroll-mt-4 flex-col gap-6 px-4 pt-14 sm:px-8 sm:pt-20 lg:px-12"
    >
      <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <h2
          id="servidores-titulo"
          class="grow font-display text-2xl font-semibold tracking-[-0.02em] sm:text-[2rem]"
        >
          {title(@design, "servers")}
        </h2>
        <span
          :if={@read_at}
          class="flex items-center gap-1.5 text-[0.8125rem] font-semibold text-[var(--sh-accent-text)]"
        >
          <span class="shop-dot size-[7px]"></span>{gettext("live")}
        </span>
        <span :if={@read_at} id="servers-updated" class="text-[0.8125rem] text-[var(--sh-text-3)]">
          {updated_ago(@read_at, @now)}
        </span>
      </div>
      <div class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        <.server_card :for={entry <- @live} entry={entry} />
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp server_card(assigns) do
    assigns = assign(assigns, :art, live_art(assigns.entry))

    ~H"""
    <article
      id={"server-#{@entry.server.id}"}
      class="shop-art relative h-[12.5rem] rounded-3xl [.shop-theme-desert_&]:rounded-[1.125rem]"
    >
      <img src={@art.src} alt={@art.alt} class="shop-art-img" />
      <div class="shop-art-card-scrim"></div>
      <div class="relative flex h-full flex-col gap-1.5 px-[1.375rem] pt-[1.125rem] pb-5">
        <div class="flex items-center justify-between gap-2">
          <span class={[
            "shop-pill shop-stencil flex h-[1.625rem] items-center gap-1.5 px-2.5 text-xs font-semibold",
            status_pill(@entry.status)
          ]}>
            <span class="shop-dot size-1.5"></span>{status_label(@entry.status)}
          </span>
          <span
            :if={queue(@entry) > 0}
            class="shop-pill shop-img-warn px-[9px] py-1 text-xs font-semibold"
          >
            {queue_label(queue(@entry))}
          </span>
          <span
            :if={queue(@entry) == 0 and @entry.status == :seeding}
            class="text-xs text-[var(--sh-img-text-2)]"
          >
            {gettext("Help fill it")}
          </span>
        </div>
        <span class="grow"></span>
        <div class="flex items-end justify-between gap-3">
          <span class="flex min-w-0 flex-col gap-0.5">
            <strong class="truncate font-display text-[1.3125rem] font-semibold">
              {@entry.server.name}
            </strong>
            <span class="truncate text-[0.8125rem] text-[var(--sh-img-text-2)]">
              {map_line(@entry.live)}
            </span>
          </span>
          <span :if={@entry.status in [:live, :seeding]} class="font-display text-2xl font-bold">
            {@entry.live.players}<span
              :if={@entry.live.max_players}
              class="text-sm text-[var(--sh-img-text-3)]"
            >/{@entry.live.max_players}</span>
          </span>
        </div>
        <span
          :if={@entry.status in [:live, :seeding]}
          class="mt-1.5 flex h-1.5 rounded-[3px] bg-[color-mix(in_oklab,var(--sh-img-text)_18%,transparent)]"
        >
          <span
            class={[
              "rounded-[3px]",
              if(@entry.status == :seeding,
                do: "bg-[#7fd6c2] [.shop-theme-arctic_&]:bg-[#1c6b58]",
                else: "bg-[var(--sh-img-accent)]"
              )
            ]}
            style={"width: #{fill_percent(@entry.live)}%"}
          ></span>
        </span>
      </div>
    </article>
    """
  end

  defp status_pill(:live), do: "shop-img-pill"
  defp status_pill(:seeding), do: "shop-img-seed"
  defp status_pill(_offline), do: "shop-glass !border-0 text-[var(--sh-img-text-2)]"

  defp status_label(:live), do: gettext("Live")
  defp status_label(:seeding), do: gettext("Seeding")
  defp status_label(:offline), do: gettext("Offline")
  defp status_label(:loading), do: gettext("Reading…")

  defp map_line(%{map: map, mode: mode}) when is_binary(map),
    do:
      Enum.join(
        Enum.reject(
          [map, mode && HllConditionalActionsWeb.LiveComponents.mode_label(mode)],
          &is_nil/1
        ),
        " · "
      )

  defp map_line(:error), do: gettext("Not answering right now")
  defp map_line(:loading), do: ""
  defp map_line(_live), do: ""

  defp fill_percent(%{players: players, max_players: max}) when is_integer(max) and max > 0,
    do: min(round(players * 100 / max), 100)

  defp fill_percent(_live), do: 0

  defp updated_ago(read_at, now) do
    seconds = max(DateTime.diff(now, read_at), 0)

    if seconds < 60,
      do: gettext("updated %{count} s ago", count: seconds),
      else: gettext("updated %{count} min ago", count: div(seconds, 60))
  end

  # ── Home: questions ────────────────────────────────────────────────────────

  attr :design, :map, required: true
  attr :settings, :map, required: true

  @doc "The questions, beside a way to ask the team."
  def faq(assigns) do
    assigns =
      assigns
      |> assign(:items, faq_items(assigns.design))
      |> assign(:discord, (assigns.settings.social_links || %{})["discord"])

    ~H"""
    <section
      id="duvidas"
      aria-labelledby="duvidas-titulo"
      class="scroll-mt-4 px-4 pt-14 sm:px-8 sm:pt-20 lg:px-12"
    >
      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 lg:auto-rows-[minmax(8.75rem,auto)]">
        <div class="flex flex-col gap-2.5 pt-1 pr-6">
          <h2
            id="duvidas-titulo"
            class="font-display text-2xl font-semibold tracking-[-0.02em] sm:text-[2rem]"
          >
            {title(@design, "faq")}
          </h2>
          <p class="text-sm leading-normal text-[var(--sh-text-2)]">
            {gettext("Did not find your answer? Type")}
            <span class="font-mono text-[var(--sh-text)]">!admin</span>
            {gettext("in the game or open a ticket on %{shop}'s Discord.", shop: shop_name(@settings))}
          </p>
          <a
            :if={@discord}
            href={@discord}
            target="_blank"
            rel="noopener noreferrer"
            class="shop-link text-sm"
          >
            {gettext("Open the Discord")}
          </a>
        </div>
        <div
          :for={item <- @items}
          class="shop-panel flex flex-col gap-2 rounded-[1.375rem] px-6 py-[1.375rem] [.shop-theme-desert_&]:rounded-[1.125rem]"
        >
          <h3 class="text-base font-semibold">{item["q"]}</h3>
          <p class="text-sm leading-normal whitespace-pre-line text-[var(--sh-text-2)]">
            {item["a"]}
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp faq_items(design) do
    case design["faq"] do
      [_ | _] = items -> items
      _none -> default_faq()
    end
  end

  # ── Home: closing call ─────────────────────────────────────────────────────

  attr :design, :map, required: true
  attr :settings, :map, required: true
  attr :package, :any, default: nil
  attr :servers, :list, default: []
  attr :art, :string, required: true

  @doc "The closing call to buy the highlighted package."
  def closing_cta(assigns) do
    ~H"""
    <section
      id="chamada"
      aria-label={gettext("Closing call")}
      class="shop-art mx-4 mt-10 rounded-[1.75rem] [.shop-theme-desert_&]:rounded-[1.25rem]"
    >
      <img src={@art} alt="" class="shop-art-img" />
      <div class="absolute inset-0 z-[-1] bg-[color-mix(in_oklab,var(--sh-img-bg)_86%,transparent)] sm:bg-[linear-gradient(90deg,color-mix(in_oklab,var(--sh-img-bg)_94%,transparent)_0%,color-mix(in_oklab,var(--sh-img-bg)_80%,transparent)_55%,color-mix(in_oklab,var(--sh-img-bg)_45%,transparent)_100%)]">
      </div>
      <div class="relative flex flex-col gap-5 px-6 py-7 sm:min-h-[8.125rem] sm:flex-row sm:items-center sm:gap-6 sm:px-12 sm:py-0">
        <div class="flex grow flex-col gap-1.5">
          <h2 class="font-display text-2xl font-semibold tracking-[-0.02em] sm:text-[2rem]">
            {title(@design, "cta")}
          </h2>
          <span :if={@package} class="text-[0.9375rem] text-[var(--sh-img-text-2)]">
            {cta_line(@package, @servers, @settings)}
          </span>
        </div>
        <.link
          :if={@package}
          navigate={~p"/shop/buy/#{@package.id}"}
          id="closing-cta"
          class="shop-btn shop-btn-light h-[3.25rem] shrink-0 gap-2.5 pr-6 pl-[26px] text-[0.9375rem]"
        >
          {gettext("I want %{name}", name: short_package_name(@package))}
          <.icon name="hero-arrow-right" class="size-[18px]" />
        </.link>
      </div>
    </section>
    """
  end

  defp cta_line(package, servers, settings) do
    [
      gettext("%{package} for %{price}",
        package: package.name,
        price: VipShop.format_money(package.price_cents, package.currency)
      ),
      duration_on_servers(package, servers, settings)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp duration_on_servers(package, _servers, settings) do
    count = length(package.servers)

    case package.duration_days do
      nil ->
        nil

      days ->
        ngettext(
          "%{days} on %{shop}'s server",
          "%{days} on %{shop}'s %{count} servers",
          count,
          days: duration(days),
          shop: shop_name(settings)
        )
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc "The shop's name."
  def shop_name(settings), do: settings.shop_title || gettext("VIP shop")

  @doc "A customer's name to show."
  def customer_name(nil), do: ""
  def customer_name(customer), do: customer.name || customer.discord_username || customer.email

  @doc "How long a package lasts, in words."
  def duration(nil), do: gettext("forever")
  def duration(days), do: ngettext("%{count} day", "%{count} days", days)

  @doc "\"Pix ou cartão\": the ways to pay, as a phrase that starts a line."
  def methods_short(methods), do: methods |> methods_text() |> capitalize_first()

  @doc "\"Pix ou cartão\" inside a sentence."
  def methods_text(methods), do: methods |> Enum.map(&method_name/1) |> join_or()

  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize_first(text), do: text

  @doc "\"Pix, cartão ou boleto\"."
  def methods_long(methods), do: methods_short(methods)

  @doc "The name of a way to pay."
  def method_name(:pix), do: "Pix"
  def method_name(:card), do: gettext("card")
  def method_name(:boleto), do: gettext("boleto")

  defp join_or([]), do: ""
  defp join_or([one]), do: one

  defp join_or(items) do
    {init, [last]} = Enum.split(items, -1)
    gettext("%{items} or %{last}", items: Enum.join(init, ", "), last: last)
  end

  @doc "A section heading: the admin's text, or the translated default."
  def title(design, key), do: get_in(design, ["titles", key]) || default_title(key)

  @doc "The translated default of a section heading."
  def default_title("benefits"), do: gettext("Why go VIP")
  def default_title("packages"), do: gettext("Choose your package")
  def default_title("packages_subtitle"), do: nil
  def default_title("servers"), do: gettext("Where the VIP counts")
  def default_title("faq"), do: gettext("Questions")
  def default_title("cta"), do: gettext("A full server stops being a problem.")
  def default_title("cta_subtitle"), do: nil
  def default_title(_key), do: nil

  @doc "The translated default of a sign in or sign up text."
  def auth_default("login_title"), do: gettext("Your place in the queue is one click away.")

  def auth_default("login_subtitle"),
    do: gettext("Sign in to pick your player, pay and follow the VIP reaching each server.")

  def auth_default("register_title"), do: gettext("One account, VIP on every server.")

  def auth_default("register_subtitle"),
    do:
      gettext(
        "With an account you link your player once, pay and watch the VIP reach each server."
      )

  def auth_default("reset_title"), do: gettext("Forgot it? We reopen the gate.")
  def auth_default("reset_subtitle"), do: nil
  def auth_default("panel_title"), do: nil
  def auth_default("panel_text"), do: nil
  def auth_default(_key), do: nil

  defp default_benefits do
    [
      %{
        "icon" => "arrow-up-tray",
        "title" => gettext("Front of the queue"),
        "short" => gettext("Front of the queue"),
        "text" =>
          gettext(
            "Server full? You go straight to the top of the queue and take the next slot that opens."
          )
      },
      %{
        "icon" => "shield-check",
        "title" => gettext("Reserved slot"),
        "short" => gettext("Reserved slot"),
        "text" =>
          gettext(
            "The servers keep slots for VIPs only. With 100/100 on the scoreboard, you still get in."
          )
      },
      %{
        "icon" => "tag",
        "title" => gettext("Tag and spotlight"),
        "short" => gettext("VIP tag"),
        "text" =>
          gettext(
            "A VIP tag on Discord and a spotlight on the community board. And you help keep the servers up."
          )
      }
    ]
  end

  defp default_faq do
    [
      %{
        "q" => gettext("How do I get the VIP?"),
        "a" =>
          gettext(
            "Sign in with Discord or email, pick your player by the name shown in the game and pay. The VIP is applied on the servers directly, no admin needed."
          )
      },
      %{
        "q" => gettext("How long does it take?"),
        "a" =>
          gettext(
            "Card is instant. Pix usually takes up to 2 minutes. You follow the delivery server by server on the order page."
          )
      },
      %{
        "q" => gettext("Can I give it as a gift?"),
        "a" =>
          gettext(
            "Yes. At checkout, turn on “Give as a gift” and search the player by name. They get a message in the game and do not need an account."
          )
      },
      %{
        "q" => gettext("What if I am already VIP?"),
        "a" =>
          gettext(
            "The days add up. With 10 days left, buying the monthly package leaves you with 40. Nothing you have is lost."
          )
      },
      %{
        "q" => gettext("Is there a refund?"),
        "a" =>
          gettext(
            "If the delivery fails, we refund you. Changed your mind? Ask within 7 days on Discord, as consumer law says."
          )
      }
    ]
  end

  @doc false
  def default_design_lists, do: %{"benefits" => default_benefits(), "faq" => default_faq()}

  defp social_links(settings) do
    links = settings.social_links || %{}

    for network <- HllConditionalActions.VipShop.Settings.social_networks(),
        url = links[network],
        is_binary(url),
        do: {network, url}
  end
end
