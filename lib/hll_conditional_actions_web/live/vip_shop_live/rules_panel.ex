defmodule HllConditionalActionsWeb.VipShopLive.RulesPanel do
  @moduledoc """
  The shop's settings pages after the VipSettings board: a menu of the
  sections with where each stands and whether the shop is open, and the
  section itself - how customers sign in, or the purchase rules (currency,
  what a repeat purchase does, the reminder before the VIP ends).
  Rendered by `HllConditionalActionsWeb.VipShopLive.Settings`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Emails, Settings}
  alias HllConditionalActionsWeb.Endpoint
  alias HllConditionalActionsWeb.VipShopLive.{Overview, SetupGuide}

  @currencies [
    {"BRL", "Real"},
    {"USD", "US Dollar"},
    {"EUR", "Euro"},
    {"GBP", "Pound"},
    {"ARS", "Peso argentino"}
  ]

  attr :section, :atom, required: true
  attr :settings, :map, required: true
  attr :providers, :list, required: true
  attr :open, :boolean, required: true
  slot :inner_block, required: true

  def layout(assigns) do
    live = Enum.count(assigns.providers, &(&1.enabled and &1.mode == "live"))
    on = Enum.count(assigns.providers, & &1.enabled)

    assigns =
      assigns
      |> assign(
        :payments_line,
        cond do
          live > 0 ->
            ngettext("%{count} provider in production", "%{count} providers in production", live)

          on > 0 ->
            ngettext("%{count} provider in test", "%{count} providers in test", on)

          true ->
            gettext("none on")
        end
      )

    ~H"""
    <div class="grid items-start gap-5 lg:grid-cols-[15rem_minmax(0,1fr)]">
      <aside class="flex flex-col gap-5">
        <nav
          aria-label={gettext("Settings sections")}
          class="flex flex-col gap-1 rounded-[1.75rem] bg-base-100 p-3.5"
        >
          <.nav_item
            path={~p"/vip-shop/settings/payments"}
            title={gettext("Payments")}
            line={@payments_line}
            current={false}
          />
          <.nav_item
            path={~p"/vip-shop/settings/login"}
            title={gettext("Customer sign in")}
            line={login_line(@settings)}
            current={@section == :login}
          />
          <.nav_item
            path={~p"/vip-shop/settings/email"}
            title={gettext("E-mail")}
            line={email_line(@settings)}
            current={false}
          />
          <.nav_item
            path={~p"/vip-shop/settings/general"}
            title={gettext("Purchase rules")}
            line={"#{@settings.currency} · #{stacking_label(@settings.stacking)}"}
            current={@section == :general}
          />
        </nav>
        <div class="flex flex-col gap-2 rounded-[1.375rem] bg-base-100 px-[1.125rem] py-4">
          <span class="flex items-center gap-2 text-[0.8125rem] font-semibold">
            <span class={["vip-dot", if(@open, do: "vip-dot-ok", else: "bg-[var(--vip-warn-fill)]")]}></span>
            {if @open, do: gettext("Shop live"), else: gettext("Shop closed")}
          </span>
          <span class="font-mono text-xs text-subtle">{SetupGuide.shop_host()}</span>
          <span class="text-xs leading-normal text-muted">
            {gettext("Changes to payment keys only count after saving and testing the webhook.")}
          </span>
          <button
            :if={@open}
            type="button"
            id="close-shop"
            phx-click="close-shop"
            data-confirm={
              gettext("Close the shop? Visitors will not be able to buy until you open it again.")
            }
            class="self-start text-xs text-subtle underline-offset-2 hover:underline"
          >
            {gettext("Close the shop")}
          </button>
          <button
            :if={!@open and @settings.closed}
            type="button"
            id="reopen-shop"
            phx-click="open-shop"
            class="self-start text-xs text-primary"
          >
            {gettext("Open the shop")}
          </button>
        </div>
      </aside>

      <div class="flex min-w-0 flex-col gap-5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :title, :string, required: true
  attr :line, :string, required: true
  attr :current, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={@current && "true"}
      class={[
        "flex flex-col gap-0.5 rounded-2xl px-3.5 py-3",
        if(@current,
          do: "border border-line-strong bg-secondary",
          else: "border border-transparent hover:bg-secondary/60"
        )
      ]}
    >
      <span class={["text-sm", if(@current, do: "font-semibold", else: "font-medium")]}>{@title}</span>
      <span class={["text-xs", if(@current, do: "text-subtle", else: "text-muted")]}>{@line}</span>
    </.link>
    """
  end

  attr :form, :any, required: true
  attr :settings, :map, required: true
  attr :customers, :map, required: true

  def login(assigns) do
    ~H"""
    <.vip_panel id="login" label={gettext("Customer sign in")} class="flex flex-col gap-4 p-6">
      <div class="flex flex-wrap items-baseline gap-3">
        <h2 class="flex-1 font-display text-[1.375rem] font-semibold">
          {gettext("Customer sign in")}
        </h2>
        <span class="text-[0.8125rem] text-muted">{gettext("Turn on at least one way to sign in.")}</span>
      </div>
      <.form
        for={@form}
        id="login-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-4"
      >
        <div class="grid gap-4 md:grid-cols-2">
          <article class="flex flex-col gap-3.5 rounded-[1.375rem] bg-secondary p-[1.125rem]">
            <div class="flex items-center gap-3">
              <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-300 text-subtle">
                <.icon name="hero-envelope" class="size-5" />
              </span>
              <span class="flex min-w-0 flex-1 flex-col">
                <strong class="text-[0.9375rem] font-semibold">{gettext("E-mail and password")}</strong>
                <span class="text-xs text-muted">
                  {ngettext("%{count} customer", "%{count} customers", @customers.password)}
                </span>
              </span>
              <.vip_switch
                name="settings[password_login]"
                id="settings_password_login"
                checked={@form[:password_login].value in [true, "true"]}
                label={gettext("Sign in with e-mail on")}
              />
            </div>
            <p class="text-[0.8125rem] leading-normal text-subtle">
              {gettext("Customers sign up with e-mail and a password of at least 10 characters.")}
            </p>
            <span class="text-xs leading-normal text-muted">
              {gettext("Password reset uses the “Reset password” template of the E-mail section.")}
            </span>
            <span
              :for={error <- Keyword.get_values(@form.errors, :password_login)}
              class="text-xs vip-err"
            >
              {translate_error(error)}
            </span>
          </article>

          <article class="flex flex-col gap-3 rounded-[1.375rem] bg-secondary p-[1.125rem]">
            <div class="flex items-center gap-3">
              <span class="flex size-10 shrink-0 items-center justify-center rounded-xl vip-chip-eng text-xs font-bold">
                DC
              </span>
              <span class="flex min-w-0 flex-1 flex-col">
                <strong class="text-[0.9375rem] font-semibold">Discord</strong>
                <span class="text-xs text-muted">
                  {ngettext("%{count} customer", "%{count} customers", @customers.discord)}
                  <span :if={Settings.discord_ready?(@settings)}> · {gettext("connected")}</span>
                </span>
              </span>
              <.vip_switch
                name="settings[discord_login]"
                id="settings_discord_login"
                checked={@form[:discord_login].value in [true, "true"]}
                label={gettext("Sign in with Discord on")}
              />
            </div>
            <div class="grid gap-2.5 sm:grid-cols-2">
              <label class="flex flex-col gap-1.5">
                <span class="text-[0.8125rem] text-subtle">{gettext("Client ID")}</span>
                <input
                  type="text"
                  name="settings[discord_client_id]"
                  id="settings_discord_client_id"
                  value={@form[:discord_client_id].value}
                  class="vip-field !h-10 bg-base-100 font-mono !text-xs"
                />
              </label>
              <label class="flex flex-col gap-1.5">
                <span class="text-[0.8125rem] text-subtle">{gettext("Client secret")}</span>
                <input
                  type="password"
                  name="settings[discord_client_secret]"
                  id="settings_discord_client_secret"
                  value=""
                  autocomplete="off"
                  placeholder={mask(@settings.discord_client_secret) || ""}
                  class="vip-field !h-10 bg-base-100 font-mono !text-xs"
                />
              </label>
            </div>
            <span
              :for={
                error <-
                  Keyword.get_values(@form.errors, :discord_client_id) ++
                    Keyword.get_values(@form.errors, :discord_client_secret)
              }
              class="text-xs vip-err"
            >
              {translate_error(error)}
            </span>
            <div class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">
                {gettext("Return URL")}
                <span class="text-muted">{gettext("(paste in the Discord portal)")}</span>
              </span>
              <span class="flex h-10 items-center gap-1.5 rounded-xl border border-line-raised bg-base-100 pl-3 pr-1">
                <span class="min-w-0 flex-1 truncate font-mono text-xs text-subtle">{discord_callback()}</span>
                <.copy_button
                  id="copy-discord-callback"
                  value={discord_callback()}
                  class="h-[1.875rem] rounded-full bg-secondary px-2.5 text-xs text-subtle"
                />
              </span>
            </div>
          </article>
        </div>

        <div class="flex items-center gap-3 rounded-[1.125rem] bg-secondary px-4 py-3.5">
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <span class="text-sm">{gettext("Link the player before paying")}</span>
            <span class="text-xs text-muted">
              {gettext(
                "The customer finds their own player searching CRCON's history. Gifts ask for the player who gets it. Always on: the VIP needs a player."
              )}
            </span>
          </span>
          <.vip_switch
            name="link_player"
            checked={true}
            disabled
            label={gettext("Link the player before paying")}
          />
        </div>
      </.form>
    </.vip_panel>
    """
  end

  attr :form, :any, required: true
  attr :settings, :map, required: true
  attr :expiring_week, :integer, required: true
  attr :example, :any, default: nil
  attr :webhooks, :list, required: true

  def general(assigns) do
    days = assigns.form[:reminder_days].value

    assigns =
      assigns
      |> assign(:days, (is_integer(days) && days) || parse_int(days) || 0)
      |> assign(:currencies, currencies(assigns.settings.currency))

    ~H"""
    <.vip_panel id="regras" label={gettext("Purchase rules")} class="flex flex-col gap-4 p-6">
      <h2 class="font-display text-[1.375rem] font-semibold">{gettext("Purchase rules")}</h2>
      <.form
        for={@form}
        id="general-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-4"
      >
        <div class="grid items-stretch gap-4 lg:grid-cols-[15rem_minmax(0,1.4fr)_minmax(0,1fr)]">
          <div class="flex flex-col gap-2.5 rounded-[1.375rem] bg-secondary p-[1.125rem]">
            <span class="text-[0.8125rem] text-subtle">{gettext("Currency")}</span>
            <label class="relative flex h-11 items-center gap-2 rounded-xl border border-line-raised bg-base-100 px-3.5">
              <select
                name="settings[currency]"
                id="settings_currency"
                class="w-full cursor-pointer appearance-none border-0 bg-transparent p-0 font-mono text-[0.8125rem] focus:ring-0"
              >
                <option
                  :for={{code, name} <- @currencies}
                  value={code}
                  selected={@form[:currency].value == code}
                >
                  {code} · {name}
                </option>
              </select>
              <.icon
                name="hero-chevron-down"
                class="pointer-events-none absolute right-3.5 size-4 text-subtle"
              />
            </label>
            <span class="text-xs leading-normal text-muted">
              {gettext(
                "Default for new packages. Each package keeps the currency it was created with."
              )}
            </span>
          </div>

          <div class="flex flex-col gap-2.5 rounded-[1.375rem] bg-secondary p-[1.125rem]">
            <span class="text-[0.8125rem] text-subtle">{gettext("When someone who is VIP buys again")}</span>
            <div
              role="radiogroup"
              aria-label={gettext("Repeat purchase")}
              class="grid gap-2 sm:grid-cols-2"
            >
              <label
                :for={
                  {value, title, text} <- [
                    {"extend", gettext("Extend"),
                     gettext("adds the days to the VIP they already have")},
                    {"replace", gettext("Replace"),
                     gettext("the new package starts today and the old one ends")}
                  ]
                }
                class={[
                  "flex cursor-pointer flex-col gap-1 rounded-2xl px-3.5 py-3",
                  if(@form[:stacking].value == value,
                    do: "vip-ok-box",
                    else: "border border-line-raised bg-base-100"
                  )
                ]}
              >
                <input
                  type="radio"
                  name="settings[stacking]"
                  value={value}
                  checked={@form[:stacking].value == value}
                  class="sr-only"
                />
                <span class={[
                  "flex items-center gap-2 text-sm",
                  if(@form[:stacking].value == value, do: "font-semibold", else: "font-medium")
                ]}>
                  <span class={[
                    "size-4 rounded-full",
                    if(@form[:stacking].value == value,
                      do: "border-[5px] border-[var(--vip-dot)]",
                      else: "border-[1.5px] border-line-strong"
                    )
                  ]}></span>
                  {title}
                </span>
                <span class={[
                  "text-xs leading-[1.4]",
                  if(@form[:stacking].value == value, do: "text-subtle", else: "text-muted")
                ]}>
                  {text}
                </span>
              </label>
            </div>
            <span class="text-xs text-muted">{example_line(@example)}</span>
          </div>

          <div class="flex flex-col gap-2.5 rounded-[1.375rem] bg-secondary p-[1.125rem]">
            <span class="text-[0.8125rem] text-subtle">{gettext("Notice before it ends")}</span>
            <div class="flex items-center gap-2.5">
              <div class="flex items-center gap-1 rounded-full border border-line-raised bg-base-100 p-[3px]">
                <button
                  type="button"
                  phx-click="reminder-days"
                  phx-value-delta="-1"
                  aria-label={gettext("Fewer days")}
                  class="size-[1.875rem] rounded-full text-base text-subtle"
                >−</button>
                <span class="w-[1.625rem] text-center font-mono text-sm">{@days}</span>
                <button
                  type="button"
                  phx-click="reminder-days"
                  phx-value-delta="1"
                  aria-label={gettext("More days")}
                  class="size-[1.875rem] rounded-full text-base text-subtle"
                >+</button>
              </div>
              <input type="hidden" name="settings[reminder_days]" value={@days} />
              <span class="text-[0.8125rem] text-subtle">{gettext("days before")}</span>
            </div>
            <label class="flex items-center gap-2.5 text-[0.8125rem]">
              <input type="hidden" name="expiring_email" value="false" />
              <input
                type="checkbox"
                name="expiring_email"
                value="true"
                checked={Emails.enabled?(@settings, "expiring")}
                class="vip-check"
              />
              {gettext("“About to end” e-mail")}
            </label>
            <span class="text-xs text-muted">
              {ngettext(
                "%{count} VIP gets the notice this week.",
                "%{count} VIPs get the notice this week.",
                @expiring_week
              )}
            </span>
          </div>
        </div>

        <div class="flex flex-col gap-3 rounded-[1.375rem] bg-secondary p-[1.125rem] sm:flex-row sm:items-center">
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <span class="text-sm">{gettext("Discord alert when a paid VIP fails")}</span>
            <span class="text-xs text-muted">{gettext("It always shows in the Inbox too.")}</span>
          </span>
          <label class="relative flex h-11 items-center rounded-xl border border-line-raised bg-base-100 px-3.5 sm:w-72">
            <select
              name="settings[alert_webhook_id]"
              class="w-full cursor-pointer appearance-none border-0 bg-transparent p-0 text-[0.8125rem] focus:ring-0"
            >
              <option value="">{gettext("Only in the Inbox")}</option>
              <option
                :for={webhook <- @webhooks}
                value={webhook.id}
                selected={to_string(@form[:alert_webhook_id].value) == to_string(webhook.id)}
              >
                {webhook.name}
              </option>
            </select>
            <.icon
              name="hero-chevron-down"
              class="pointer-events-none absolute right-3.5 size-4 text-subtle"
            />
          </label>
        </div>
      </.form>
    </.vip_panel>
    """
  end

  defp example_line(%{player: player, had: had, package: package, total: total}),
    do:
      gettext("E.g.: %{player} had %{had} days and bought %{package}: ended up with %{total}.",
        player: player,
        had: had,
        package: package,
        total: total
      )

  defp example_line(_none),
    do: gettext("E.g.: 20 days left and a 30 day package: the VIP ends in 50 days.")

  defp currencies(current) do
    if Enum.any?(@currencies, fn {code, _} -> code == current end),
      do: @currencies,
      else: @currencies ++ [{current, current}]
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp login_line(settings) do
    [settings.password_login && gettext("e-mail"), settings.discord_login && "Discord"]
    |> Enum.filter(& &1)
    |> case do
      [] -> gettext("none on")
      ways -> Enum.join(ways, gettext(" and "))
    end
  end

  defp email_line(settings) do
    service =
      case settings.email_provider do
        "sendgrid" -> "SendGrid"
        "brevo" -> "Brevo"
        _smtp -> "SMTP"
      end

    if Settings.email_configured?(settings),
      do:
        service <>
          " · " <> ngettext("%{count} template", "%{count} templates", length(Emails.names())),
      else: gettext("not set up")
  end

  defp stacking_label("extend"), do: gettext("extend")
  defp stacking_label(_replace), do: gettext("replace")

  defp discord_callback, do: Endpoint.url() <> "/shop/auth/discord/callback"

  @doc """
  A real example of an extended purchase: who had how many days left, what
  they bought and how many they ended up with.
  """
  @spec extension_example() :: map() | nil
  def extension_example do
    VipShop.recent_orders(status: "fulfilled", limit: 40)
    |> Enum.find(&Overview.extended?/1)
    |> case do
      nil ->
        nil

      order ->
        until =
          order.grants
          |> Enum.map(& &1.expires_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime)

        total = div(DateTime.diff(until, order.paid_at), 86_400)

        %{
          player: order.player_name || order.player_id,
          had: total - order.duration_days,
          package: order.package_name,
          total: total
        }
    end
  end
end
