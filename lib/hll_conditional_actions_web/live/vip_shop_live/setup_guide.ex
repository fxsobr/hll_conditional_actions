defmodule HllConditionalActionsWeb.VipShopLive.SetupGuide do
  @moduledoc """
  The guide that opens the Loja VIP (VipOnboarding board): five steps from
  the first package to a test purchase, the current one open; beside it how
  the storefront looks right now and how an order becomes paid. The last
  box opens the shop to the public once the test purchase went through.
  Rendered by `HllConditionalActionsWeb.VipShopLive.Settings` at
  `/vip-shop/settings/setup`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Design, Emails, Settings}
  alias HllConditionalActionsWeb.VipShopLive.Overview

  @doc "What the guide shows."
  @spec load(Settings.t()) :: map()
  def load(%Settings{} = settings) do
    steps = VipShop.setup_steps()
    providers = VipShop.list_providers()
    enabled = Enum.filter(providers, & &1.enabled)

    %{
      steps: steps,
      current: Enum.find_value(steps, fn step -> !step.done && step.key end),
      done: Enum.count(steps, & &1.done),
      package: VipShop.list_packages() |> Enum.find(& &1.active),
      packages: Enum.count(VipShop.list_packages(), & &1.active),
      providers: providers,
      enabled: enabled,
      settings: settings,
      design: Design.get(settings.design),
      test_paid: Enum.find(steps, &(&1.key == :test_purchase)).done
    }
  end

  attr :data, :map, required: true
  attr :pick, :string, required: true

  def guide(assigns) do
    ~H"""
    <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_23.75rem]">
      <.vip_panel
        id="shop-setup"
        label={gettext("Steps to open the shop")}
        class="flex flex-col gap-2 px-5 py-6 md:px-7"
      >
        <div class="mb-2 flex flex-col gap-4 sm:flex-row sm:items-end sm:gap-6">
          <div class="flex min-w-0 flex-1 flex-col gap-1.5">
            <h2 class="font-display text-[1.625rem] font-semibold tracking-[-0.02em]">
              {gettext("Let's open the VIP shop")}
            </h2>
            <span class="text-sm text-subtle">
              {gettext("The shop stays closed until a test purchase goes through from start to end.")}
            </span>
          </div>
          <div class="flex w-full flex-col gap-2 sm:w-[12.5rem]">
            <span class="flex justify-between text-[0.8125rem] text-subtle">
              {gettext("Progress")}
              <strong class="font-mono font-medium text-base-content">
                {gettext("%{done} of %{total}", done: @data.done, total: length(@data.steps))}
              </strong>
            </span>
            <span class="vip-steps" aria-hidden="true">
              <span
                :for={step <- @data.steps}
                class={[step.done && "done", step.key == @data.current && "current"]}
              ></span>
            </span>
          </div>
        </div>

        <%= for {step, index} <- Enum.with_index(@data.steps, 1) do %>
          <%= if step.key == @data.current do %>
            <.open_step step={step} index={index} data={@data} pick={@pick} />
          <% else %>
            <.step_row step={step} index={index} data={@data} />
          <% end %>
        <% end %>

        <span class="min-h-4 flex-1"></span>

        <div class="flex flex-col gap-4 rounded-[1.25rem] border border-dashed border-line-strong px-[1.125rem] py-4 sm:flex-row sm:items-center">
          <span class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-secondary text-muted">
            <.icon
              name={if @data.settings.closed, do: "hero-lock-closed", else: "hero-lock-open"}
              class="size-5"
            />
          </span>
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <strong class="text-sm font-semibold">{gettext("Open the shop to the public")}</strong>
            <span class="text-xs leading-normal text-muted">
              <%= if @data.settings.closed do %>
                {gettext(
                  "Unlocks when the test purchase goes through: the payment arrives confirmed by the provider and the VIP shows on the servers."
                )}
              <% else %>
                {gettext("The shop is open: visitors see the packages and can buy.")}
              <% end %>
            </span>
          </span>
          <%= if @data.settings.closed do %>
            <button
              type="button"
              id="open-shop"
              phx-click="open-shop"
              disabled={not @data.test_paid}
              aria-disabled={to_string(not @data.test_paid)}
              class={["vip-btn", @data.test_paid && "vip-btn-cta"]}
            >
              <.icon
                name={if @data.test_paid, do: "hero-lock-open", else: "hero-lock-closed"}
                class="size-4"
              />
              {gettext("Open the shop")}
            </button>
          <% else %>
            <button
              type="button"
              id="close-shop"
              phx-click="close-shop"
              data-confirm={
                gettext("Close the shop? Visitors will not be able to buy until you open it again.")
              }
              class="vip-btn vip-btn-raised"
            >
              <.icon name="hero-lock-closed" class="size-4" />{gettext("Close the shop")}
            </button>
          <% end %>
        </div>
      </.vip_panel>

      <div class="flex min-w-0 flex-col gap-5">
        <.vip_panel
          label={gettext("How the shop is now")}
          class="flex flex-col gap-3.5 px-6 py-[1.375rem]"
        >
          <.vip_panel_head title={gettext("The shop now")}>
            <.dot_label class="text-xs">{gettext("live")}</.dot_label>
          </.vip_panel_head>

          <div class="overflow-hidden rounded-[1.125rem] border border-base-300 vip-well">
            <div class="flex h-[1.875rem] items-center gap-1.5 border-b border-line-soft px-3">
              <span :for={_ <- 1..3} class="size-[7px] rounded-full bg-[var(--vip-track)]"></span>
              <span class="ml-2 font-mono text-[0.6875rem] text-muted">{shop_host()}</span>
            </div>
            <div class="relative h-[12.25rem] overflow-hidden text-[#f3f2ec]">
              <img
                :if={@data.settings.banner_asset_id}
                src={~p"/shop/assets/#{@data.settings.banner_asset_id}"}
                alt=""
                class="absolute inset-0 size-full object-cover"
              />
              <div class="absolute inset-0 bg-[linear-gradient(180deg,rgba(15,16,14,0.78)_0%,rgba(15,16,14,0.92)_100%)]">
              </div>
              <div class="relative flex h-full flex-col gap-2.5 p-[1.125rem]">
                <span class="flex items-center gap-2">
                  <span class="flex size-[1.625rem] items-center justify-center overflow-hidden rounded-lg border border-[#2e3029] bg-[#20211d]">
                    <img
                      :if={@data.settings.logo_asset_id}
                      src={~p"/shop/assets/#{@data.settings.logo_asset_id}"}
                      alt=""
                      class="size-full object-cover"
                    />
                    <.icon
                      :if={!@data.settings.logo_asset_id}
                      name="hero-shield-check"
                      class="size-3.5"
                    />
                  </span>
                  <strong class="font-display text-[0.8125rem] font-bold">
                    {@data.settings.shop_title || gettext("VIP shop")}
                  </strong>
                </span>
                <span class="flex-1"></span>
                <strong class="font-display text-[1.875rem] font-bold tracking-[-0.02em]">
                  <%= if VipShop.open?() do %>
                    {get_in(@data.design, ["titles", "hero"]) || @data.settings.shop_title ||
                      gettext("VIP shop")}
                  <% else %>
                    {gettext("Coming soon")}
                  <% end %>
                </strong>
                <span class="line-clamp-2 text-xs leading-normal text-[#cfcfc6]">
                  {@data.settings.shop_subtitle ||
                    gettext("Reserved slot, tag on your name and the VIP channel on Discord.")}
                </span>
              </div>
            </div>
          </div>

          <span class="flex items-center gap-2 text-[0.8125rem]">
            <%= if VipShop.open?() do %>
              <.vip_chip tone="ok" class="font-bold">{gettext("Shop open")}</.vip_chip>
              <span class="text-subtle">{gettext("visitors see the packages")}</span>
            <% else %>
              <.vip_chip tone="warn" class="font-bold">{gettext("Shop closed")}</.vip_chip>
              <span class="text-subtle">{gettext("visitors see “Coming soon”")}</span>
            <% end %>
          </span>

          <div class="flex flex-col text-[0.8125rem]">
            <.state_line label={gettext("Packages")} last={false}>
              <span :if={@data.packages > 0} class="vip-ok">
                {ngettext("%{count} ready", "%{count} ready", @data.packages)}
              </span>
              <span :if={@data.packages == 0} class="vip-warn">{gettext("none yet")}</span>
            </.state_line>
            <.state_line label={gettext("Payment")} last={false}>
              <span :if={@data.enabled != []} class="vip-ok">
                {Enum.map_join(@data.enabled, ", ", &provider_name(&1.provider))}
              </span>
              <span :if={@data.enabled == []} class="vip-warn">{gettext("none on")}</span>
            </.state_line>
            <.state_line label={gettext("Customer sign in")} last={false}>
              <.step_state step={Enum.find(@data.steps, &(&1.key == :sign_in))} />
            </.state_line>
            <.state_line label={gettext("Receipt by e-mail")} last={false}>
              <.step_state step={Enum.find(@data.steps, &(&1.key == :email))} />
            </.state_line>
            <.state_line label={gettext("Test purchase")} last={true}>
              <%= cond do %>
                <% @data.test_paid -> %>
                  <span class="vip-ok">{gettext("paid")}</span>
                <% @data.enabled == [] -> %>
                  <span class="text-muted">{gettext("blocked")}</span>
                <% true -> %>
                  <span class="text-muted">{gettext("to do")}</span>
              <% end %>
            </.state_line>
          </div>
        </.vip_panel>

        <.vip_panel
          label={gettext("How an order becomes paid")}
          class="flex flex-1 flex-col gap-3 px-6 py-[1.375rem]"
        >
          <h3 class="font-display text-lg font-semibold">{gettext("How an order becomes paid")}</h3>
          <div
            :for={
              {icon, text} <- [
                {"hero-shield-check",
                 gettext(
                   "Only with a signed webhook or by asking the provider's API. Coming back from the payment page does not count."
                 )},
                {"hero-credit-card",
                 gettext(
                   "A refused card does not cancel the order: the customer can try again on the same link."
                 )},
                {"hero-bolt",
                 gettext(
                   "Once paid, the VIP is delivered server by server and the customer follows it live."
                 )}
              ]
            }
            class="grid grid-cols-[1.375rem_minmax(0,1fr)] gap-2.5 text-[0.8125rem] leading-[1.45] text-subtle"
          >
            <.icon name={icon} class="size-[1.125rem] text-primary" />
            <span>{text}</span>
          </div>
        </.vip_panel>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :last, :boolean, default: false
  slot :inner_block, required: true

  defp state_line(assigns) do
    ~H"""
    <div class={["flex justify-between gap-3 px-0.5 py-2", !@last && "border-b border-line-soft"]}>
      <span class="text-subtle">{@label}</span>
      <span class="text-right">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :step, :map, required: true

  defp step_state(assigns) do
    ~H"""
    <span :if={@step.done} class="vip-ok">{gettext("ready")}</span>
    <span :if={!@step.done} class="text-muted">{gettext("to do")}</span>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :data, :map, required: true

  defp step_row(assigns) do
    ~H"""
    <div
      id={"setup-#{@step.key}"}
      class="grid grid-cols-[2.125rem_minmax(0,1fr)_auto] items-center gap-3.5 rounded-2xl px-3.5 py-2"
    >
      <%= cond do %>
        <% @step.done -> %>
          <span class="flex size-[1.875rem] items-center justify-center rounded-full vip-chip-lime">
            <.icon name="hero-check" class="size-4" />
          </span>
        <% @step.key == :test_purchase -> %>
          <span class="flex size-[1.875rem] items-center justify-center rounded-full border-[1.5px] border-dashed border-[var(--vip-eng-fg)] font-mono text-[0.8125rem] vip-eng">
            {@index}
          </span>
        <% true -> %>
          <span class="flex size-[1.875rem] items-center justify-center rounded-full border-[1.5px] border-line-strong font-mono text-[0.8125rem] text-subtle">
            {@index}
          </span>
      <% end %>
      <span class="flex min-w-0 flex-col gap-px">
        <span class={["text-[0.9375rem]", if(@step.done, do: "font-semibold", else: "font-medium")]}>
          {step_title(@step.key)}
        </span>
        <span class="text-[0.8125rem] text-muted">{step_summary(@step, @data)}</span>
      </span>
      <%= cond do %>
        <% @step.done -> %>
          <.link navigate={step_path(@step.key, @data)} class="text-[0.8125rem] text-primary">
            {gettext("Revisit")}
          </.link>
        <% @step.key == :sign_in -> %>
          <span class="flex gap-1.5">
            <.vip_chip :if={@data.settings.discord_login} tone="eng">Discord</.vip_chip>
            <.vip_chip :if={@data.settings.password_login}>{gettext("E-mail")}</.vip_chip>
          </span>
        <% true -> %>
          <span class="text-xs text-muted">{step_time(@step.key)}</span>
      <% end %>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :data, :map, required: true
  attr :pick, :string, required: true

  defp open_step(assigns) do
    ~H"""
    <div
      id={"setup-#{@step.key}"}
      class="flex flex-col gap-3.5 rounded-[1.375rem] border border-line-strong bg-secondary px-5 pb-5 pt-[1.125rem]"
    >
      <div class="grid grid-cols-[2.125rem_minmax(0,1fr)_auto] items-center gap-3.5">
        <span class="flex size-[1.875rem] items-center justify-center rounded-full bg-inverse font-mono text-[0.8125rem] font-medium text-on-inverse">
          {@index}
        </span>
        <span class="flex min-w-0 flex-col gap-px">
          <span class="text-[1.0625rem] font-semibold">{step_title(@step.key)}</span>
          <span class="text-[0.8125rem] text-subtle">{step_hint(@step.key)}</span>
        </span>
        <span class="text-xs text-muted">{step_time(@step.key)}</span>
      </div>

      <%= if @step.key == :payment do %>
        <div
          role="radiogroup"
          aria-label={gettext("Payment provider")}
          class="grid gap-2.5 md:grid-cols-3"
        >
          <label
            :for={provider <- ~w(stripe dodo mercado_pago)}
            id={"setup-provider-#{provider}"}
            class={[
              "relative flex cursor-pointer flex-col gap-2 rounded-[1.125rem] bg-base-100 px-4 py-3.5",
              if(@pick == provider,
                do: "border-[1.5px] border-[var(--vip-dot)]",
                else: "border border-line-raised"
              )
            ]}
          >
            <input
              type="radio"
              name="provider"
              value={provider}
              checked={@pick == provider}
              phx-click="setup-pick"
              phx-value-provider={provider}
              class="vip-check absolute right-3.5 top-3.5"
            />
            <span class="flex items-center gap-2.5">
              <.provider_tile provider={provider} size="sm" active={@pick == provider} />
              <strong class="text-[0.9375rem] font-semibold">{provider_name(provider)}</strong>
            </span>
            <span class="text-[0.8125rem] font-medium">{provider_pitch(provider)}</span>
            <ul class="flex flex-col gap-[0.3125rem] text-xs leading-[1.35] text-muted">
              <li :for={point <- provider_points(provider)}>{point}</li>
            </ul>
          </label>
        </div>
      <% end %>

      <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
        <.step_action step={@step} data={@data} pick={@pick} />
        <span class="flex-1 text-xs leading-[1.45] text-muted">{step_needs(@step.key, @pick)}</span>
      </div>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :data, :map, required: true
  attr :pick, :string, required: true

  defp step_action(assigns) do
    ~H"""
    <%= case @step.key do %>
      <% :payment -> %>
        <.link
          navigate={~p"/vip-shop/settings/payments?provider=#{@pick}"}
          id="setup-configure"
          class="vip-btn vip-btn-cta"
        >
          {gettext("Set up %{provider}", provider: provider_name(@pick))}
          <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      <% :test_purchase -> %>
        <button
          :for={provider <- Enum.take(@data.enabled, 1)}
          type="button"
          id="setup-test-purchase"
          phx-click="test-purchase"
          phx-value-provider={provider.provider}
          class="vip-btn vip-btn-cta"
        >
          {gettext("Make a test purchase")}<.icon name="hero-arrow-right" class="size-4" />
        </button>
      <% key -> %>
        <.link navigate={step_path(key, @data)} class="vip-btn vip-btn-cta">
          {step_button(key)}<.icon name="hero-arrow-right" class="size-4" />
        </.link>
    <% end %>
    """
  end

  defp step_title(:package), do: gettext("Create the first package")
  defp step_title(:payment), do: gettext("Turn on a payment method")
  defp step_title(:sign_in), do: gettext("How the customer signs in")
  defp step_title(:email), do: gettext("Receipt e-mail")

  defp step_title(:test_purchase),
    do: gettext("Test purchase of %{amount}", amount: money(100, VipShop.settings().currency))

  defp step_hint(:package), do: gettext("Price, days of VIP and the servers it counts on.")

  defp step_hint(:payment),
    do:
      gettext(
        "Pick one to start. You can turn on all three; the customer picks at checkout among the ones that are on."
      )

  defp step_hint(:sign_in),
    do:
      gettext(
        "Discord, e-mail and password, or both. Then they link the player by searching CRCON's history"
      )

  defp step_hint(:email),
    do:
      gettext(
        "SMTP, SendGrid or Brevo. The “Purchase approved” template comes ready with the Storefront's logo"
      )

  defp step_hint(:test_purchase),
    do:
      gettext(
        "In test mode, nothing is charged. It checks the payment, the signed webhook, the VIP on CRCON and the receipt"
      )

  defp step_summary(%{key: :package, done: true}, %{package: %{} = package}) do
    Enum.join(
      [
        package.name,
        money(package.price_cents, package.currency),
        Overview.duration_label(package.duration_days),
        ngettext(
          "counts on %{count} server",
          "counts on %{count} servers",
          length(package.servers)
        )
      ],
      " · "
    )
  end

  defp step_summary(%{key: :payment, done: true}, data) do
    Enum.map_join(data.enabled, ", ", fn p ->
      provider_name(p.provider) <>
        " · " <> if(p.mode == "live", do: gettext("production"), else: gettext("test"))
    end)
  end

  defp step_summary(%{key: :sign_in, done: true}, data) do
    [
      data.settings.password_login && gettext("e-mail and password"),
      Settings.discord_ready?(data.settings) && "Discord"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp step_summary(%{key: :email, done: true}, data) do
    provider =
      case data.settings.email_provider do
        "sendgrid" -> "SendGrid"
        "brevo" -> "Brevo"
        _smtp -> "SMTP"
      end

    custom = Emails.custom?(data.settings, "purchase")

    provider <>
      " · " <>
      if(custom, do: gettext("custom receipt"), else: gettext("default receipt"))
  end

  defp step_summary(%{key: :test_purchase, done: true}, _data),
    do: gettext("Paid in test mode, confirmed by the provider")

  defp step_summary(step, _data), do: step_hint(step.key)

  defp step_time(:payment), do: "~5 min"
  defp step_time(:email), do: "~3 min"
  defp step_time(:test_purchase), do: "1 min"
  defp step_time(:package), do: "~2 min"
  defp step_time(_other), do: ""

  defp step_button(:package), do: gettext("Create package")
  defp step_button(:sign_in), do: gettext("Choose how to sign in")
  defp step_button(:email), do: gettext("Set up the e-mail")

  defp step_path(:package, %{package: %{id: id}}), do: ~p"/vip-shop/packages/#{id}/edit"
  defp step_path(:package, _data), do: ~p"/vip-shop/packages/new"
  defp step_path(:payment, _data), do: ~p"/vip-shop/settings/payments"
  defp step_path(:sign_in, _data), do: ~p"/vip-shop/settings/login"
  defp step_path(:email, _data), do: ~p"/vip-shop/settings/email"
  defp step_path(:test_purchase, _data), do: ~p"/vip-shop/settings/payments"

  defp step_needs(:payment, "stripe"),
    do:
      gettext(
        "You will need: a restricted key with Checkout Sessions, 1 webhook with 4 events and its whsec_ secret. The key decides test or production."
      )

  defp step_needs(:payment, "dodo"),
    do:
      gettext(
        "You will need: an API key with write access, 1 webhook registered and its whsec_ secret. Starts in test mode."
      )

  defp step_needs(:payment, "mercado_pago"),
    do:
      gettext(
        "You will need: the Access Token of a Checkout Pro application and, optionally, the webhook's secret signature."
      )

  defp step_needs(:test_purchase, _pick),
    do:
      gettext("%{amount} on the provider's checkout in test mode. Nothing is charged.",
        amount: money(100, VipShop.settings().currency)
      )

  defp step_needs(_step, _pick), do: ""

  @doc "What a provider is good at, as the guide pitches it."
  def provider_pitch("stripe"), do: gettext("Cards from all over the world")
  def provider_pitch("dodo"), do: gettext("Pix + card, handles the taxes")
  def provider_pitch("mercado_pago"), do: gettext("Pix, card and boleto")

  @doc "The three facts under a provider's pitch."
  def provider_points("stripe"),
    do: [
      gettext("Restricted key, only Checkout Sessions"),
      gettext("Test or production: the key itself decides"),
      gettext("Webhook with 4 events")
    ]

  def provider_points("dodo"),
    do: [
      gettext("Sells as merchant of record"),
      gettext("Separate keys for test and production"),
      gettext("Creates the VIP product by itself on the 1st checkout")
    ]

  def provider_points("mercado_pago"),
    do: [
      gettext("Checkout Pro application"),
      gettext("TEST- or APP_USR- Access Token"),
      gettext("Webhook signature optional")
    ]

  @doc "The host the public shop answers on, as a browser shows it."
  def shop_host do
    uri = URI.parse(HllConditionalActionsWeb.Endpoint.url())
    "#{uri.host}#{if uri.port not in [80, 443], do: ":#{uri.port}"}/shop"
  end
end
