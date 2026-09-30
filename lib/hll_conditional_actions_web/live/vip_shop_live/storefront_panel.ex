defmodule HllConditionalActionsWeb.VipShopLive.StorefrontPanel do
  @moduledoc """
  The storefront editor (VipStorefront board): the look - theme, accent
  colour, logo and banner - and the page's sections, switched on, titled
  and reordered by dragging; beside them a live preview, on a computer or a
  phone. Edits are kept as a draft until "Publicar vitrine".

  Everything else the public page can say (names and texts, social links,
  the top's layout, the benefits and the questions, the sign in screens)
  is under "Mais ajustes da vitrine".
  Rendered by `HllConditionalActionsWeb.VipShopLive.Settings`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop.{Design, Settings}
  alias HllConditionalActionsWeb.ShopComponents
  alias HllConditionalActionsWeb.VipShopLive.{Overview, SetupGuide}

  @accents [
    {"#d2f36b", "Lime"},
    {"#7fd6c2", "Teal"},
    {"#f4c95d", "Amber"},
    {"#ff9c95", "Coral"},
    {"#c3b3ff", "Lavender"}
  ]

  attr :draft, :map, required: true
  attr :published, :map, required: true
  attr :settings, :map, required: true
  attr :page_form, :any, required: true
  attr :uploads, :map, required: true
  attr :assets, :map, required: true
  attr :packages, :list, required: true
  attr :servers, :list, required: true
  attr :live, :map, required: true
  attr :preview_mode, :string, required: true
  attr :more_open, :boolean, default: false

  def storefront(assigns) do
    tokens = Design.theme(assigns.draft["theme"])
    accent = assigns.draft["accent"] || tokens.accent

    assigns =
      assigns
      |> assign(:tokens, tokens)
      |> assign(:accent, accent)
      |> assign(:contrast, contrast(accent, tokens.bg))

    ~H"""
    <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_37.5rem]">
      <div class="flex min-w-0 flex-col gap-5">
        <.form
          for={%{}}
          as={:design}
          id="design-form"
          phx-change="design-change"
          phx-submit="design-save"
          class="flex flex-col gap-5"
        >
          <.vip_panel label={gettext("Appearance")} class="flex flex-col gap-3 px-[1.375rem] py-5">
            <h2 class="font-display text-xl font-semibold">{gettext("Appearance")}</h2>

            <div class="flex flex-col gap-2">
              <span class="text-[0.8125rem] text-subtle">{gettext("Theme")}</span>
              <div
                role="radiogroup"
                aria-label={gettext("Theme")}
                class="grid grid-cols-3 gap-2.5 sm:grid-cols-5"
              >
                <label
                  :for={name <- Design.themes()}
                  id={"theme-#{name}"}
                  class={[
                    "flex cursor-pointer flex-col gap-1.5 rounded-2xl bg-secondary p-1.5 transition",
                    if(@draft["theme"] == name,
                      do: "border border-[var(--vip-dot)] shadow-[0_0_0_3px_var(--vip-ok-soft)]",
                      else: "border border-line-raised hover:border-line-strong"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    name="design[theme]"
                    value={name}
                    checked={@draft["theme"] == name}
                    class="sr-only"
                  />
                  <span
                    class="flex h-[2.875rem] flex-col justify-end gap-1 rounded-[0.6875rem] p-[0.4375rem]"
                    style={"background: #{Design.theme(name).bg}"}
                  >
                    <span
                      class="h-[5px] w-3/5 rounded-[3px]"
                      style={"background: #{Design.theme(name).text}"}
                    ></span>
                    <span class="flex gap-1">
                      <span
                        class="h-2.5 w-[1.375rem] rounded-[3px]"
                        style={"background: #{Design.theme(name).accent}"}
                      ></span>
                      <span
                        class="h-2.5 w-[1.375rem] rounded-[3px]"
                        style={"background: #{Design.theme(name).surface}"}
                      ></span>
                    </span>
                  </span>
                  <span class={[
                    "flex justify-between px-1 pb-0.5 text-xs",
                    @draft["theme"] == name && "font-semibold"
                  ]}>
                    {theme_name(name)}
                    <.icon :if={@draft["theme"] == name} name="hero-check" class="size-3.5 vip-ok" />
                  </span>
                </label>
              </div>
            </div>

            <div class="flex flex-col gap-2">
              <span class="text-[0.8125rem] text-subtle">{gettext("Accent colour")}</span>
              <div class="flex flex-wrap items-center gap-2.5">
                <div role="radiogroup" aria-label={gettext("Accent colour")} class="flex gap-2">
                  <button
                    :for={{hex, label} <- accents()}
                    type="button"
                    role="radio"
                    aria-checked={to_string(String.downcase(@accent) == hex)}
                    aria-label={label}
                    phx-click="accent-pick"
                    phx-value-color={hex}
                    class="size-7 rounded-full"
                    style={
                      "background: #{hex};" <>
                        if(String.downcase(@accent) == hex,
                          do: " box-shadow: 0 0 0 2px var(--color-base-100), 0 0 0 4px var(--color-base-content)",
                          else: ""
                        )
                    }
                  ></button>
                </div>
                <input
                  type="hidden"
                  name="design[custom_accent]"
                  value={to_string(@draft["accent"] != nil)}
                />
                <label class="ml-1.5 flex h-[2.375rem] items-center gap-2 rounded-xl border border-line-raised bg-secondary px-3">
                  <span class="size-3.5 rounded" style={"background: #{@accent}"}></span>
                  <input
                    type="text"
                    name="design[accent]"
                    id="design-accent"
                    value={String.upcase(@accent)}
                    maxlength="7"
                    phx-debounce="400"
                    aria-label={gettext("Colour in hexadecimal")}
                    class="w-[4.75rem] border-0 bg-transparent p-0 font-mono text-[0.8125rem] focus:ring-0"
                  />
                </label>
                <span :if={@contrast >= 3} class="flex items-center gap-1.5 text-xs vip-ok">
                  <.icon name="hero-check" class="size-3.5" />{gettext("readable on the background")}
                </span>
                <span :if={@contrast < 3} class="flex items-center gap-1.5 text-xs vip-warn">
                  <.icon name="hero-exclamation-triangle" class="size-3.5" />{gettext(
                    "low contrast with the background"
                  )}
                </span>
              </div>
            </div>

            <div class="grid gap-2.5 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
              <.image_tile
                label={gettext("Logo")}
                upload={@uploads.logo}
                asset={@assets.logo}
                field="logo_asset_id"
                square
              />
              <.image_tile
                label={gettext("Banner")}
                upload={@uploads.banner}
                asset={@assets.banner}
                field="banner_asset_id"
                removable
              />
            </div>
          </.vip_panel>

          <.vip_panel
            label={gettext("Page sections")}
            class="flex flex-1 flex-col gap-3 px-[1.375rem] py-5"
          >
            <.vip_panel_head title={gettext("Page sections")}>
              <span class="text-xs text-muted">{gettext("drag to reorder")}</span>
            </.vip_panel_head>

            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Top title")}</span>
              <input
                type="text"
                name="design[titles][hero]"
                id="title-hero"
                value={get_in(@draft, ["titles", "hero"])}
                placeholder={@settings.shop_title || gettext("VIP shop")}
                phx-debounce="400"
                class={[
                  "vip-field",
                  changed?(@draft, @published, ["titles", "hero"]) && "vip-changed"
                ]}
              />
            </label>

            <.sort_list id="design-sections" event="design-reorder" class="flex flex-col gap-1.5">
              <div
                :for={section <- @draft["sections"]}
                id={"section-#{section["key"]}"}
                data-sort-id={section["key"]}
                class={[
                  "grid grid-cols-[0.875rem_2.5rem_minmax(0,1fr)] items-center gap-3 rounded-[0.875rem] px-2.5 py-[0.4375rem] sm:grid-cols-[0.875rem_2.5rem_6.5rem_minmax(0,1fr)]",
                  if(section["enabled"] or section["key"] == "packages",
                    do: "bg-secondary",
                    else: "border border-dashed border-line-raised"
                  )
                ]}
              >
                <.grip label={gettext("Drag to reorder")} />
                <%= if section["key"] == "packages" do %>
                  <input type="hidden" name="design[sections][packages]" value="true" />
                  <span
                    title={gettext("Packages always show")}
                    class="flex h-6 w-10 items-center justify-center rounded-full bg-[color-mix(in_oklab,var(--vip-lime)_35%,transparent)] text-[var(--vip-on-lime)]"
                  >
                    <.icon name="hero-lock-closed" class="size-3" />
                  </span>
                <% else %>
                  <.vip_switch
                    name={"design[sections][#{section["key"]}]"}
                    id={"section-on-#{section["key"]}"}
                    checked={section["enabled"]}
                    label={gettext("Show %{section}", section: section_name(section["key"]))}
                  />
                <% end %>
                <span class={[
                  "text-sm font-medium",
                  !(section["enabled"] or section["key"] == "packages") && "text-subtle"
                ]}>
                  {section_name(section["key"])}
                  <span :if={section["key"] == "faq"} class="text-[0.6875rem] font-normal text-muted">
                    {ngettext("%{count} question", "%{count} questions", length(@draft["faq"] || []))}
                  </span>
                </span>
                <input
                  type="text"
                  name={"design[titles][#{section["key"]}]"}
                  id={"title-#{section["key"]}"}
                  value={get_in(@draft, ["titles", section["key"]])}
                  placeholder={ShopComponents.default_title(section["key"])}
                  phx-debounce="400"
                  aria-label={gettext("Title of %{section}", section: section_name(section["key"]))}
                  class={[
                    "col-span-3 h-[2.125rem] rounded-[0.625rem] border bg-base-100 px-3 text-[0.8125rem] outline-0 sm:col-span-1",
                    if(changed?(@draft, @published, ["titles", section["key"]]),
                      do: "border-[var(--vip-warn-line)]",
                      else: "border-line-raised"
                    )
                  ]}
                />
              </div>
            </.sort_list>

            <details
              id="storefront-more"
              open={@more_open}
              class="group mt-2 rounded-2xl border border-line-raised"
            >
              <summary class="flex cursor-pointer list-none items-center gap-2 px-4 py-3 text-sm font-medium">
                <.icon name="hero-adjustments-horizontal" class="size-4 text-subtle" />
                <span class="flex-1">{gettext("More storefront settings")}</span>
                <span class="text-xs text-muted">{gettext(
                  "top layout, benefits, questions, sign in screens"
                )}</span>
                <.icon
                  name="hero-chevron-down"
                  class="size-4 text-muted transition group-open:rotate-180"
                />
              </summary>
              <.more_settings draft={@draft} settings={@settings} uploads={@uploads} />
            </details>
          </.vip_panel>
        </.form>

        <.page_texts :if={@more_open} form={@page_form} settings={@settings} />
        <.link
          :if={!@more_open}
          patch={~p"/vip-shop/settings"}
          id="edit-texts"
          class="self-start px-2 text-[0.8125rem] text-primary"
        >
          {gettext("Edit the shop's name, texts and social links")}
        </.link>
      </div>

      <.preview
        draft={@draft}
        settings={@settings}
        packages={@packages}
        servers={@servers}
        live={@live}
        mode={@preview_mode}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :upload, :any, required: true
  attr :asset, :map, default: nil
  attr :field, :string, required: true
  attr :square, :boolean, default: false
  attr :removable, :boolean, default: false

  defp image_tile(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <span class="text-[0.8125rem] text-subtle">{@label}</span>
      <div
        class="flex items-center gap-3 rounded-2xl border border-dashed border-line-strong bg-secondary p-2.5"
        phx-drop-target={@upload.ref}
      >
        <span
          :if={!@asset}
          class={[
            "flex h-[3.25rem] shrink-0 items-center justify-center rounded-[0.875rem] bg-base-300 text-muted",
            if(@square, do: "w-[3.25rem]", else: "w-[6.5rem]")
          ]}
        >
          <.icon name="hero-photo" class="size-5" />
        </span>
        <img
          :if={@asset}
          src={~p"/shop/assets/#{@asset.id}"}
          alt=""
          class={[
            "h-[3.25rem] shrink-0 object-cover",
            if(@square, do: "w-[3.25rem] rounded-[0.875rem]", else: "w-[6.5rem] rounded-[0.625rem]")
          ]}
        />
        <span class="flex min-w-0 flex-1 flex-col gap-[0.1875rem]">
          <%= cond do %>
            <% entry = List.first(@upload.entries) -> %>
              <span class="truncate font-mono text-xs">{entry.client_name}</span>
              <span class="text-[0.6875rem] text-muted">{entry.progress}%</span>
              <span :for={error <- upload_errors(@upload, entry)} class="text-[0.6875rem] vip-err">
                {upload_error(error)}
              </span>
            <% @asset -> %>
              <span class="truncate font-mono text-xs">
                {if @square, do: gettext("logo"), else: gettext("banner")}.{String.downcase(
                  @asset.format
                )}
              </span>
              <span class="text-[0.6875rem] text-muted">
                <span :if={@asset.width}>{@asset.width}×{@asset.height} · </span>{@asset.format} · {kb(
                  @asset.bytes
                )}
              </span>
            <% true -> %>
              <span class="text-xs text-subtle">{gettext("No image")}</span>
              <span class="text-[0.6875rem] text-muted">{gettext("PNG, JPG or WebP up to 2 MB")}</span>
          <% end %>
        </span>
        <label class="flex h-[1.875rem] cursor-pointer items-center rounded-full border border-line-raised px-2.5 text-xs">
          {if @asset, do: gettext("Change"), else: gettext("Upload")}
          <.live_file_input upload={@upload} class="sr-only" />
        </label>
        <button
          :if={@removable and @asset}
          type="button"
          phx-click="remove-draft-image"
          phx-value-field={@field}
          aria-label={gettext("Remove %{image}", image: String.downcase(@label))}
          class="flex size-[1.875rem] items-center justify-center rounded-full border border-line-raised text-muted"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
    </div>
    """
  end

  attr :draft, :map, required: true
  attr :settings, :map, required: true
  attr :uploads, :map, required: true

  defp more_settings(assigns) do
    ~H"""
    <div class="flex flex-col gap-5 border-t border-line-soft px-4 py-4">
      <div class="flex flex-col gap-2">
        <span class="text-[0.8125rem] text-subtle">{gettext("Top of the page")}</span>
        <div class="grid grid-cols-3 gap-2">
          <label
            :for={hero <- Design.heroes()}
            class={[
              "flex cursor-pointer flex-col items-center gap-1.5 rounded-xl p-2 text-xs",
              if(@draft["hero"] == hero,
                do: "vip-ok-box font-semibold",
                else: "border border-line-raised"
              )
            ]}
          >
            <input
              type="radio"
              name="design[hero]"
              value={hero}
              checked={@draft["hero"] == hero}
              class="sr-only"
            />
            {Labels.shop_hero(hero)}
          </label>
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <input
            type="text"
            name="design[cta_label]"
            id="design-cta"
            value={@draft["cta_label"]}
            placeholder={gettext("See VIP packages")}
            aria-label={gettext("Main button text")}
            class="vip-field"
          />
          <label class="flex items-center gap-2.5 text-[0.8125rem]">
            <input type="hidden" name="design[uppercase]" value="false" />
            <input
              type="checkbox"
              name="design[uppercase]"
              value="true"
              checked={@draft["uppercase"]}
              class="vip-check"
            />
            {gettext("Military style headings (uppercase)")}
          </label>
        </div>
      </div>

      <div class="flex flex-col gap-2">
        <span class="text-[0.8125rem] text-subtle">{gettext("Benefits")}</span>
        <div
          :for={{row, i} <- Enum.with_index(@draft["benefits"] || [])}
          class="grid grid-cols-[6.5rem_minmax(0,1fr)_auto] gap-2"
        >
          <select name={"design[benefits][#{i}][icon]"} class="vip-field">
            <option :for={icon <- Design.icons()} value={icon} selected={row["icon"] == icon}>
              {icon}
            </option>
          </select>
          <div class="grid gap-2 sm:grid-cols-2">
            <input
              type="text"
              name={"design[benefits][#{i}][title]"}
              value={row["title"]}
              placeholder={gettext("Title")}
              class="vip-field"
            />
            <input
              type="text"
              name={"design[benefits][#{i}][text]"}
              value={row["text"]}
              placeholder={gettext("Short description")}
              class="vip-field"
            />
          </div>
          <button
            type="button"
            phx-click="design-remove"
            phx-value-list="benefits"
            phx-value-index={i}
            aria-label={gettext("Remove")}
            class="text-muted hover:text-base-content"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
        <button
          :if={length(@draft["benefits"] || []) < 6}
          type="button"
          phx-click="design-add"
          phx-value-list="benefits"
          class="self-start text-[0.8125rem] text-primary"
        >
          + {gettext("Add a benefit")}
        </button>
      </div>

      <div class="flex flex-col gap-2">
        <span class="text-[0.8125rem] text-subtle">{gettext("Frequently asked questions")}</span>
        <div
          :for={{row, i} <- Enum.with_index(@draft["faq"] || [])}
          class="grid grid-cols-[minmax(0,1fr)_auto] gap-2"
        >
          <div class="flex flex-col gap-2">
            <input
              type="text"
              name={"design[faq][#{i}][q]"}
              value={row["q"]}
              placeholder={gettext("Question")}
              class="vip-field"
            />
            <textarea
              name={"design[faq][#{i}][a]"}
              rows="2"
              placeholder={gettext("Answer")}
              class="vip-field"
            >{row["a"]}</textarea>
          </div>
          <button
            type="button"
            phx-click="design-remove"
            phx-value-list="faq"
            phx-value-index={i}
            aria-label={gettext("Remove")}
            class="self-start pt-3 text-muted hover:text-base-content"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
        <button
          :if={length(@draft["faq"] || []) < 10}
          type="button"
          phx-click="design-add"
          phx-value-list="faq"
          class="self-start text-[0.8125rem] text-primary"
        >
          + {gettext("Add a question")}
        </button>
      </div>

      <div class="flex flex-col gap-3">
        <span class="text-[0.8125rem] text-subtle">{gettext("Sign in and sign up screens")}</span>
        <div class="grid gap-3 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <div class="flex flex-col gap-2">
            <div class="aspect-[3/4] overflow-hidden rounded-xl border border-base-300 bg-secondary">
              <img
                :if={@draft["auth"]["image_id"] || @draft["banner_asset_id"]}
                src={~p"/shop/assets/#{@draft["auth"]["image_id"] || @draft["banner_asset_id"]}"}
                alt=""
                class="size-full object-cover"
              />
            </div>
            <label class="cursor-pointer text-center text-xs text-primary">
              {gettext("Change image")}
              <.live_file_input upload={@uploads.auth_image} class="sr-only" />
            </label>
            <label :if={@draft["auth"]["image_id"]} class="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name="design[auth][remove_image]"
                value="true"
                class="vip-check !size-4"
              />
              {gettext("Use the banner")}
            </label>
          </div>
          <div class="flex flex-col gap-2.5">
            <div class="vip-seg vip-seg-sm self-start">
              <label :for={
                {side, label} <- [
                  {"left", gettext("Image on the left")},
                  {"right", gettext("Image on the right")}
                ]
              }>
                <input
                  type="radio"
                  name="design[auth][side]"
                  value={side}
                  checked={@draft["auth"]["side"] == side}
                />
                {label}
              </label>
            </div>
            <label class="flex items-center gap-2.5 text-[0.8125rem]">
              <input type="hidden" name="design[auth][show_benefits]" value="false" />
              <input
                type="checkbox"
                name="design[auth][show_benefits]"
                value="true"
                checked={@draft["auth"]["show_benefits"]}
                class="vip-check"
              />
              {gettext("Show the benefits over the image")}
            </label>
            <div class="grid gap-2 sm:grid-cols-2">
              <input
                :for={key <- Design.auth_text_keys()}
                type="text"
                name={"design[auth][texts][#{key}]"}
                id={"auth-#{key}"}
                value={get_in(@draft, ["auth", "texts", key])}
                placeholder={ShopComponents.auth_default(key) || Labels.shop_auth_text(key)}
                aria-label={Labels.shop_auth_text(key)}
                class="vip-field"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :settings, :map, required: true

  defp page_texts(assigns) do
    ~H"""
    <.vip_panel
      id="page-texts"
      label={gettext("Names and texts")}
      class="flex flex-col gap-3 px-[1.375rem] py-5"
    >
      <h2 class="font-display text-xl font-semibold">{gettext("Names and texts")}</h2>
      <.form
        for={@form}
        id="page-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Shop name")}</span>
            <input
              type="text"
              name="settings[shop_title]"
              value={@form[:shop_title].value}
              class="vip-field"
            />
          </label>
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Subtitle")}</span>
            <input
              type="text"
              name="settings[shop_subtitle]"
              value={@form[:shop_subtitle].value}
              class="vip-field"
            />
          </label>
        </div>
        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Welcome text")}</span>
          <textarea name="settings[shop_description]" rows="4" class="vip-field">{@form[:shop_description].value}</textarea>
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Footer text")}</span>
          <textarea name="settings[footer_text]" rows="2" class="vip-field">{@form[:footer_text].value}</textarea>
        </label>
        <label class="flex items-center gap-2.5 text-[0.8125rem]">
          <input type="hidden" name="settings[show_servers]" value="false" />
          <input
            type="checkbox"
            name="settings[show_servers]"
            value="true"
            checked={@form[:show_servers].value in [true, "true"]}
            class="vip-check"
          />
          {gettext("Show which servers each package covers")}
        </label>
        <span class="mt-1 text-[0.8125rem] text-subtle">{gettext("Social links")}</span>
        <div class="grid gap-2 sm:grid-cols-2">
          <label :for={network <- Settings.social_networks()} class="vip-field">
            <span class="w-20 shrink-0 text-xs text-muted">{Labels.social_network(network)}</span>
            <input
              type="url"
              name={"settings[social_links][#{network}]"}
              id={"social-#{network}"}
              value={Map.get(@settings.social_links || %{}, network)}
              placeholder="https://"
            />
          </label>
        </div>
        <span :for={error <- Keyword.get_values(@form.errors, :social_links)} class="text-xs vip-err">
          {translate_error(error)}
        </span>
        <button type="submit" class="vip-btn vip-btn-cta self-start">{gettext("Save texts")}</button>
      </.form>
    </.vip_panel>
    """
  end

  attr :draft, :map, required: true
  attr :settings, :map, required: true
  attr :packages, :list, required: true
  attr :servers, :list, required: true
  attr :live, :map, required: true
  attr :mode, :string, required: true

  defp preview(assigns) do
    lists = ShopComponents.default_design_lists()

    assigns =
      assigns
      |> assign(
        :sections,
        Design.enabled_sections(assigns.draft) |> Enum.uniq() |> ensure_packages()
      )
      |> assign(:benefits, assigns.draft["benefits"] || lists["benefits"])
      |> assign(:faq, assigns.draft["faq"] || lists["faq"])
      |> assign(
        :off,
        Enum.reject(assigns.draft["sections"], &(&1["enabled"] or &1["key"] == "packages"))
      )
      |> assign(:phone, assigns.mode == "phone")

    ~H"""
    <.vip_panel
      id="storefront-preview"
      label={gettext("Store preview")}
      class="flex min-w-0 flex-col gap-3.5 px-[1.375rem] py-5"
    >
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Preview")}</h2>
        <div
          role="radiogroup"
          aria-label={gettext("Screen size")}
          class="flex gap-1 rounded-full bg-secondary p-[3px]"
        >
          <button
            :for={{mode, label} <- [{"desktop", gettext("Computer")}, {"phone", gettext("Phone")}]}
            type="button"
            role="radio"
            aria-checked={to_string(@mode == mode)}
            phx-click="preview-mode"
            phx-value-mode={mode}
            class={[
              "h-[1.875rem] rounded-full px-3 text-xs",
              if(@mode == mode, do: "bg-inverse font-semibold text-on-inverse", else: "text-subtle")
            ]}
          >
            {label}
          </button>
        </div>
        <a
          href={~p"/shop"}
          target="_blank"
          rel="noopener"
          class="flex items-center gap-1.5 text-[0.8125rem] text-primary"
        >
          {gettext("Open the shop")}<.icon name="hero-arrow-up-right" class="size-3.5" />
        </a>
      </div>

      <div
        class={[
          "vip-shop-preview flex min-h-0 flex-1 flex-col overflow-hidden rounded-[1.25rem] border border-line-raised",
          @phone && "mx-auto w-full max-w-[20rem]"
        ]}
        style={Design.css_vars(@draft)}
      >
        <div class="flex h-[2.125rem] shrink-0 items-center gap-1.5 border-b border-line-raised bg-secondary px-3">
          <span :for={_ <- 1..3} class="size-2 rounded-full bg-line-strong"></span>
          <span class="ml-2.5 flex h-[1.375rem] flex-1 items-center rounded-full bg-base-100 px-2.5 font-mono text-[0.6875rem] text-muted">
            {SetupGuide.shop_host()}
          </span>
        </div>

        <div class="relative h-44 shrink-0">
          <img
            :if={@draft["banner_asset_id"]}
            src={~p"/shop/assets/#{@draft["banner_asset_id"]}"}
            alt=""
            class="absolute inset-0 size-full object-cover"
          />
          <div
            class="absolute inset-0"
            style="background: linear-gradient(180deg, color-mix(in srgb, var(--shop-bg) 55%, transparent) 0%, color-mix(in srgb, var(--shop-bg) 70%, transparent) 50%, var(--shop-bg) 100%)"
          >
          </div>
          <div class="relative flex h-full flex-col gap-1.5 px-[1.125rem] pb-4 pt-3">
            <div class="flex items-center gap-2">
              <span class="sp-accent flex size-6 items-center justify-center overflow-hidden rounded-[0.4375rem]">
                <img
                  :if={@draft["logo_asset_id"]}
                  src={~p"/shop/assets/#{@draft["logo_asset_id"]}"}
                  alt=""
                  class="size-full object-cover"
                />
                <.icon :if={!@draft["logo_asset_id"]} name="hero-chevron-double-up" class="size-3.5" />
              </span>
              <span class="flex-1 truncate text-xs font-semibold">{@settings.shop_title ||
                gettext("VIP shop")}</span>
              <span :if={!@phone} class="sp-muted text-[0.625rem]">
                {gettext("Packages")} · {gettext("Servers")} · {gettext("Sign in")}
              </span>
            </div>
            <span class="flex-1"></span>
            <strong class={[
              "font-display text-[1.625rem] font-bold leading-[1.05] tracking-[-0.02em]",
              @draft["uppercase"] && "uppercase"
            ]}>
              {get_in(@draft, ["titles", "hero"]) || @settings.shop_title || gettext("VIP shop")}
            </strong>
            <span :if={@settings.shop_subtitle} class="sp-muted line-clamp-2 text-[0.6875rem]">
              {@settings.shop_subtitle}
            </span>
            <span class="sp-accent mt-1 flex h-[1.625rem] items-center self-start rounded-full px-3 text-[0.6875rem] font-semibold">
              {@draft["cta_label"] || gettext("See packages")}
            </span>
          </div>
        </div>

        <div class="flex flex-col gap-3.5 px-[1.125rem] pb-4 pt-3.5">
          <%= for key <- @sections do %>
            <%= case key do %>
              <% "benefits" -> %>
                <div class="flex flex-col gap-2">
                  <span class="font-display text-sm font-semibold">{ShopComponents.title(
                    @draft,
                    "benefits"
                  )}</span>
                  <div class={["grid gap-2", if(@phone, do: "grid-cols-1", else: "grid-cols-3")]}>
                    <span
                      :for={item <- Enum.take(@benefits, 3)}
                      class="sp-surface flex flex-col gap-0.5 rounded-[0.625rem] px-2.5 py-2"
                    >
                      <span class="text-[0.6875rem] font-semibold">{item["title"]}</span>
                      <span class="sp-muted text-[0.625rem]">{item["text"]}</span>
                    </span>
                  </div>
                </div>
              <% "packages" -> %>
                <div class="flex flex-col gap-2">
                  <span class="font-display text-sm font-semibold">{ShopComponents.title(
                    @draft,
                    "packages"
                  )}</span>
                  <p :if={@packages == []} class="sp-muted text-[0.6875rem]">
                    {gettext("No package on sale yet.")}
                  </p>
                  <div class={["grid gap-2", if(@phone, do: "grid-cols-1", else: "grid-cols-3")]}>
                    <span
                      :for={package <- Enum.take(@packages, 3)}
                      class={[
                        "flex flex-col gap-[0.1875rem] rounded-xl p-2.5",
                        if(package.highlight, do: "sp-accent-card", else: "sp-surface")
                      ]}
                    >
                      <span class={[
                        "flex justify-between text-[0.625rem]",
                        !package.highlight && "sp-muted",
                        package.highlight && "opacity-80"
                      ]}>
                        {Overview.duration_label(package.duration_days)}
                        <span :if={package.highlight} class="font-bold">{package.highlight}</span>
                      </span>
                      <span class="truncate text-xs font-semibold">{package.name}</span>
                      <span class="flex items-baseline gap-1.5">
                        <span class="font-display text-[1.0625rem] font-bold">{money(
                          package.price_cents,
                          package.currency
                        )}</span>
                        <span
                          :if={package.compare_at_cents}
                          class="text-[0.625rem] line-through opacity-70"
                        >
                          {money(package.compare_at_cents, package.currency)}
                        </span>
                      </span>
                    </span>
                  </div>
                </div>
              <% "servers" -> %>
                <div class="flex flex-col gap-1.5">
                  <span class="font-display text-sm font-semibold">{ShopComponents.title(
                    @draft,
                    "servers"
                  )}</span>
                  <span
                    :for={server <- @servers}
                    class="sp-surface flex items-center gap-2 rounded-lg px-2.5 py-1.5 text-[0.6875rem]"
                  >
                    <span class={[
                      "size-1.5 rounded-full",
                      if(is_map(@live[server.id]), do: "sp-accent", else: "bg-[#8c8e85]")
                    ]}></span>
                    <span class="flex-1 truncate">
                      {server.name}<span :if={is_map(@live[server.id]) and @live[server.id].map}> · {@live[
                        server.id
                      ].map}</span>
                    </span>
                    <span :if={is_map(@live[server.id])} class="sp-muted font-mono">
                      {@live[server.id].players}/{@live[server.id].max_players || "?"}
                    </span>
                  </span>
                </div>
              <% "faq" -> %>
                <div class="flex flex-col gap-1.5">
                  <span class="font-display text-sm font-semibold">{ShopComponents.title(
                    @draft,
                    "faq"
                  )}</span>
                  <span
                    :for={item <- Enum.take(@faq, 2)}
                    class="sp-surface rounded-lg px-2.5 py-1.5 text-[0.6875rem]"
                  >
                    {item["q"]}
                  </span>
                </div>
              <% "cta" -> %>
                <div class="sp-surface flex items-center gap-2.5 rounded-xl px-3.5 py-3">
                  <span class="flex-1 font-display text-[0.9375rem] font-semibold">{ShopComponents.title(
                    @draft,
                    "cta"
                  )}</span>
                  <span class="sp-accent flex h-[1.625rem] items-center rounded-full px-3 text-[0.6875rem] font-semibold">
                    {@draft["cta_label"] || gettext("I want VIP")}
                  </span>
                </div>
              <% _other -> %>
            <% end %>
          <% end %>
        </div>
      </div>
      <span class="text-xs text-muted">
        <span :for={section <- @off}>
          {gettext("%{section} is off and does not show.", section: section_name(section["key"]))}
        </span>
        {gettext("The preview uses the active packages.")}
      </span>
    </.vip_panel>
    """
  end

  defp ensure_packages(keys), do: if("packages" in keys, do: keys, else: keys ++ ["packages"])

  @doc "The accent presets, as `{hex, name}`."
  def accents, do: Enum.map(@accents, fn {hex, name} -> {hex, accent_name(name)} end)

  defp accent_name("Lime"), do: gettext("Lime")
  defp accent_name("Teal"), do: gettext("Teal")
  defp accent_name("Amber"), do: gettext("Amber")
  defp accent_name("Coral"), do: gettext("Coral")
  defp accent_name("Lavender"), do: gettext("Lavender")

  @doc "A theme's name."
  def theme_name("tactical"), do: gettext("Tactical")
  def theme_name("crimson"), do: gettext("Crimson")
  def theme_name("midnight"), do: gettext("Midnight")
  def theme_name("desert"), do: gettext("Desert")
  def theme_name("arctic"), do: gettext("Arctic")
  def theme_name(other), do: other

  @doc "A section's name."
  def section_name("benefits"), do: gettext("Benefits")
  def section_name("packages"), do: gettext("Packages")
  def section_name("servers"), do: gettext("Servers")
  def section_name("faq"), do: gettext("FAQ")
  def section_name("cta"), do: gettext("Final call")
  def section_name(other), do: other

  defp changed?(draft, published, path), do: get_in(draft, path) != get_in(published, path)

  # WCAG contrast ratio between two colours.
  defp contrast(a, b) do
    {la, lb} = {luminance(a), luminance(b)}
    {hi, lo} = if la > lb, do: {la, lb}, else: {lb, la}
    (hi + 0.05) / (lo + 0.05)
  end

  defp luminance("#" <> hex) when byte_size(hex) == 6 do
    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        c = String.to_integer(pair, 16) / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp luminance(_other), do: 0.0

  defp kb(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp kb(bytes), do: "#{max(round(bytes / 1000), 1)} KB"

  defp upload_error(:too_large), do: gettext("File too large")
  defp upload_error(:not_accepted), do: gettext("File type not accepted")
  defp upload_error(:too_many_files), do: gettext("Only one file")
  defp upload_error(_other), do: gettext("Upload failed")
end
