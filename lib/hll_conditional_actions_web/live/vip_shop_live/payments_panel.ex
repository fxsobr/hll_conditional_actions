defmodule HllConditionalActionsWeb.VipShopLive.PaymentsPanel do
  @moduledoc """
  The payment methods (VipPayments board): one card per provider with its
  state, its keys as stored and its health - do the keys work, is the
  webhook arriving - then the webhooks received; on the right the provider
  being set up, step by step, ending in a test purchase.
  Rendered by `HllConditionalActionsWeb.VipShopLive.Settings`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{PaymentProvider, Stats}
  alias HllConditionalActionsWeb.Endpoint
  alias HllConditionalActionsWeb.VipShopLive.SetupGuide

  @doc "What the page shows besides the providers."
  @spec load() :: map()
  def load do
    webhooks = Stats.webhooks(8)
    order_ids = webhooks |> Enum.map(& &1.order_id) |> Enum.reject(&is_nil/1)

    tests =
      if order_ids == [],
        do: MapSet.new(),
        else:
          order_ids
          |> Enum.map(&VipShop.get_order/1)
          |> Enum.filter(&(&1 && &1.test))
          |> MapSet.new(& &1.id)

    %{
      webhooks: webhooks,
      test_orders_seen: tests,
      counts: Stats.webhook_counts(24),
      share: Stats.provider_share(30),
      currency: VipShop.settings().currency || "BRL"
    }
  end

  attr :providers, :list, required: true
  attr :editing, :string, default: nil
  attr :provider_form, :any, default: nil
  attr :test_orders, :map, required: true
  attr :data, :map, required: true

  def payments(assigns) do
    assigns =
      assign(assigns, :current, Enum.find(assigns.providers, &(&1.provider == assigns.editing)))

    ~H"""
    <div class={["grid gap-5", @current && "xl:grid-cols-[minmax(0,1fr)_33.75rem]"]}>
      <div class="flex min-w-0 flex-col gap-3.5">
        <p class="px-1 text-[0.8125rem] leading-[1.45] text-subtle">
          {gettext(
            "The checkout shows only the providers that are on. An order only becomes paid by a signed webhook or by asking the provider's API; a refused card does not cancel the order."
          )}
        </p>

        <div id="payment-providers" class="flex flex-col gap-3.5">
          <.provider_card
            :for={provider <- @providers}
            provider={provider}
            editing={provider.provider == @editing}
            share={Map.get(@data.share, provider.provider)}
            currency={@data.currency}
          />
        </div>

        <.vip_panel
          id="webhook-log"
          class="flex min-h-[10rem] flex-1 flex-col gap-2 !rounded-3xl px-5 py-4"
        >
          <div class="flex flex-wrap items-baseline gap-2">
            <h2 class="flex-1 font-display text-[1.0625rem] font-semibold">
              {gettext("Webhooks received")}
            </h2>
            <span class="text-xs text-muted">
              {gettext("last 24 h · %{ok} ok · %{refused} refused",
                ok: @data.counts.ok,
                refused: @data.counts.refused
              )}
            </span>
          </div>
          <p :if={@data.webhooks == []} class="py-3 text-xs text-muted">
            {gettext("No webhook has arrived yet.")}
          </p>
          <div
            :for={{event, index} <- Enum.with_index(@data.webhooks)}
            id={"webhook-#{event.id}"}
            class={[
              "grid grid-cols-[3.875rem_minmax(0,1fr)_auto] items-center gap-2.5 py-[0.4375rem] text-xs sm:grid-cols-[3.875rem_7.25rem_minmax(0,1fr)_auto]",
              index < length(@data.webhooks) - 1 && "border-b border-line-soft"
            ]}
          >
            <.vip_time
              id={"webhook-at-#{event.id}"}
              at={event.inserted_at}
              format="clock"
              class="font-mono text-muted"
            />
            <span class="hidden truncate text-subtle sm:block">{webhook_source(event, @providers)}</span>
            <span class="truncate font-mono text-[0.6875rem]">
              {event.event || "—"}<span :if={event.order_id}> · {gettext("order")} #{if MapSet.member?(
                                                                                          @data.test_orders_seen,
                                                                                          event.order_id
                                                                                        ),
                                                                                        do: "T-"}{event.order_id}</span>
            </span>
            <span :if={event.ok} class="vip-ok">{gettext("signature ok")}</span>
            <span :if={!event.ok} class="max-w-[12rem] truncate vip-err" title={event.error}>
              {gettext("refused")}: {event.error}
            </span>
          </div>
        </.vip_panel>
      </div>

      <.config_panel
        :if={@current}
        provider={@current}
        form={@provider_form}
        test_order={@test_orders[@current.provider]}
        currency={@data.currency}
      />
    </div>
    """
  end

  defp webhook_source(event, providers) do
    provider = Enum.find(providers, &(&1.provider == event.provider))
    name = event.provider |> provider_name() |> String.replace(" Payments", "")

    if (provider && provider.mode == "test") and event.provider != "stripe",
      do: name <> " · " <> gettext("test"),
      else: name
  end

  attr :provider, PaymentProvider, required: true
  attr :editing, :boolean, default: false
  attr :share, :integer, default: nil
  attr :currency, :string, required: true

  defp provider_card(assigns) do
    p = assigns.provider
    creds = p.credentials || %{}

    assigns =
      assigns
      |> assign(:creds, creds)
      |> assign(:facts, facts(p, creds, assigns.currency))
      |> assign(
        :webhook_failing,
        p.last_webhook_error_at != nil and
          (p.last_webhook_at == nil or DateTime.after?(p.last_webhook_error_at, p.last_webhook_at))
      )

    ~H"""
    <article
      id={"provider-#{@provider.provider}"}
      aria-label={provider_name(@provider.provider)}
      class={[
        "flex flex-col gap-3 rounded-3xl bg-base-100 px-5 py-[1.125rem]",
        @editing && "vip-selected"
      ]}
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class={[
          "flex size-10 shrink-0 items-center justify-center rounded-xl text-xs font-bold",
          if(@editing, do: "vip-chip-ok", else: "bg-base-300 text-subtle")
        ]}>
          {provider_initials(@provider.provider)}
        </span>
        <span class="flex min-w-0 flex-1 flex-col gap-px">
          <strong class="text-[0.9375rem] font-semibold">{provider_name(@provider.provider)}</strong>
          <span class="truncate text-xs text-muted">
            {SetupGuide.provider_pitch(@provider.provider)}<span :if={@share}> · {gettext(
              "%{pct}% of orders",
              pct: @share
            )}</span>
          </span>
        </span>

        <%= if @provider.provider == "stripe" do %>
          <.state_pill provider={@provider} />
        <% else %>
          <div
            role="radiogroup"
            aria-label={gettext("State of %{provider}", provider: provider_name(@provider.provider))}
            class="flex gap-0.5 rounded-full border border-line-raised bg-secondary p-[3px]"
          >
            <button
              :for={
                {state, label} <- [
                  {"off", gettext("Off")},
                  {"test", gettext("In test")},
                  {"live", gettext("Production")}
                ]
              }
              type="button"
              role="radio"
              id={"state-#{@provider.provider}-#{state}"}
              aria-checked={to_string(provider_state(@provider) == state)}
              phx-click="set-state"
              phx-value-provider={@provider.provider}
              phx-value-state={state}
              class={[
                "h-7 rounded-full px-2.5 text-xs",
                cond do
                  provider_state(@provider) != state -> "text-subtle hover:text-base-content"
                  state == "test" -> "bg-[var(--vip-eng-fg)] font-semibold text-base-100"
                  state == "live" -> "bg-[var(--vip-dot)] font-semibold text-base-100"
                  true -> "bg-inverse font-semibold text-on-inverse"
                end
              ]}
            >
              {label}
            </button>
          </div>
        <% end %>

        <span
          :if={@editing}
          class="flex h-9 items-center rounded-full bg-inverse px-3.5 text-[0.8125rem] font-semibold text-on-inverse"
        >
          {gettext("Editing")}
        </span>
        <.link
          :if={!@editing}
          patch={~p"/vip-shop/settings/payments?provider=#{@provider.provider}"}
          id={"configure-#{@provider.provider}"}
          class="vip-btn vip-btn-raised vip-btn-md !h-9"
        >
          {gettext("Configure")}
        </.link>
      </div>

      <div :if={@facts != []} class="flex flex-wrap gap-1.5">
        <span
          :for={{kind, text} <- @facts}
          class={[
            "bg-secondary px-[0.5625rem] py-1 text-[0.6875rem] text-subtle",
            if(kind == :key, do: "rounded-lg font-mono", else: "rounded-full font-semibold")
          ]}
        >
          {text}
        </span>
      </div>

      <div
        id={"health-#{@provider.provider}"}
        class="grid gap-2 sm:grid-cols-[14.625rem_minmax(0,1fr)]"
      >
        <span class="flex items-center gap-2 rounded-[0.875rem] bg-secondary px-3 py-2.5 text-xs text-subtle">
          <%= cond do %>
            <% not Map.has_key?(@creds, key_field(@provider.provider)) -> %>
              <span class="vip-dot bg-muted"></span>
              <span class="flex-1">{gettext("No key yet")}</span>
            <% @provider.checked_at == nil -> %>
              <span class="vip-dot bg-muted"></span>
              <span class="flex-1">{gettext("Key not tested yet")}</span>
            <% @provider.check_error -> %>
              <span class="vip-dot bg-error"></span>
              <span class="min-w-0 flex-1 truncate" title={@provider.check_error}>
                <strong class="font-semibold vip-err">{gettext("Key refused")}</strong>
                · {@provider.check_error}
              </span>
            <% true -> %>
              <span class="vip-dot vip-dot-ok"></span>
              <span class="min-w-0 flex-1 truncate">
                <strong class="font-semibold text-base-content">{key_ok_label(@provider.provider)}</strong>
                · {gettext("tested")}
                <.vip_time
                  id={"checked-#{@provider.provider}"}
                  at={@provider.checked_at}
                  format="ago"
                />
              </span>
          <% end %>
          <button
            :if={Map.has_key?(@creds, key_field(@provider.provider))}
            type="button"
            id={"check-#{@provider.provider}"}
            phx-click="check-provider"
            phx-value-provider={@provider.provider}
            aria-label={gettext("Test the key again")}
            title={gettext("Test the key again")}
            class="shrink-0 text-muted hover:text-base-content"
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
          </button>
        </span>

        <%= cond do %>
          <% @webhook_failing -> %>
            <span class="flex min-w-0 items-center gap-2 rounded-[0.875rem] border border-[color-mix(in_oklab,var(--vip-err-fg)_35%,transparent)] px-3 py-2.5 text-xs text-subtle">
              <span class="vip-dot bg-error"></span>
              <span class="truncate" title={@provider.last_webhook_error}>
                <strong class="font-semibold vip-err">{gettext("Webhook refused")}:</strong>
                {@provider.last_webhook_error} ·
                <.vip_time
                  id={"webhook-error-#{@provider.provider}"}
                  at={@provider.last_webhook_error_at}
                  format="ago"
                />
              </span>
            </span>
          <% @provider.last_webhook_at -> %>
            <span class="flex min-w-0 items-center gap-2 rounded-[0.875rem] bg-secondary px-3 py-2.5 text-xs text-subtle">
              <span class="vip-dot vip-dot-ok"></span>
              <span class="truncate">
                <strong class="font-semibold text-base-content">{gettext("Last webhook:")}</strong>
                <span class="font-mono text-[0.6875rem]">{@provider.last_webhook_event || "—"}</span>
                <.vip_time
                  id={"webhook-#{@provider.provider}"}
                  at={@provider.last_webhook_at}
                  format="ago"
                /> · {gettext("signature ok")}
              </span>
            </span>
          <% true -> %>
            <span class="vip-warn-box flex min-w-0 items-center gap-2 rounded-[0.875rem] px-3 py-2.5 text-xs text-subtle">
              <span class="vip-dot bg-[var(--vip-warn-fill)]"></span>
              <span class="truncate">
                <strong class="font-semibold vip-warn">{gettext("No webhook received yet")}</strong>
                · {webhook_hint(@provider.provider)}
              </span>
            </span>
        <% end %>
      </div>
    </article>
    """
  end

  attr :provider, PaymentProvider, required: true

  defp state_pill(assigns) do
    ~H"""
    <%= cond do %>
      <% @provider.enabled and @provider.mode == "live" -> %>
        <span class="vip-chip vip-chip-ok h-7 gap-1.5 px-[0.6875rem] text-xs">
          <span class="vip-dot size-1.5 vip-dot-ok"></span>{gettext("Production")}
        </span>
      <% @provider.enabled -> %>
        <span class="vip-chip vip-chip-eng h-7 gap-1.5 px-[0.6875rem] text-xs">
          <span class="vip-dot size-1.5"></span>{gettext("In test")}
        </span>
      <% true -> %>
        <button
          :if={@provider.id}
          type="button"
          id={"state-#{@provider.provider}-on"}
          phx-click="set-state"
          phx-value-provider={@provider.provider}
          phx-value-state="on"
          class="vip-chip h-7 px-[0.6875rem] text-xs"
        >
          {gettext("Off · turn on")}
        </button>
        <span :if={!@provider.id} class="vip-chip h-7 px-[0.6875rem] text-xs">{gettext("Off")}</span>
    <% end %>
    <button
      :if={@provider.enabled}
      type="button"
      id={"state-#{@provider.provider}-off"}
      phx-click="set-state"
      phx-value-provider={@provider.provider}
      phx-value-state="off"
      aria-label={gettext("Turn off")}
      title={gettext("Turn off")}
      class="text-muted hover:text-base-content"
    >
      <.icon name="hero-power" class="size-4" />
    </button>
    """
  end

  @doc "Off, test or live."
  def provider_state(%{enabled: false}), do: "off"
  def provider_state(%{mode: "live"}), do: "live"
  def provider_state(_provider), do: "test"

  defp key_field("stripe"), do: "secret_key"
  defp key_field("dodo"), do: "api_key"
  defp key_field("mercado_pago"), do: "access_token"

  defp key_ok_label("mercado_pago"), do: gettext("Token valid")
  defp key_ok_label(_provider), do: gettext("Key valid")

  defp webhook_hint("mercado_pago"), do: gettext("check the Payments topic")
  defp webhook_hint(_provider), do: gettext("check the events of the endpoint")

  # The chips under a provider's name: its key as stored and what to know.
  defp facts(%{provider: "stripe"} = p, creds, _currency) do
    key = creds["secret_key"]

    [
      key && {:key, mask(key)},
      key &&
        {:fact,
         if(String.starts_with?(key, "rk_"),
           do: gettext("restricted · only Checkout Sessions"),
           else: gettext("full secret key · prefer a restricted one")
         )},
      p.id && {:fact, gettext("no mode switch · the key decides")}
    ]
    |> Enum.filter(& &1)
  end

  defp facts(%{provider: "dodo"} = p, creds, currency) do
    key = creds["api_key"]

    [
      key &&
        {:key,
         if(p.mode == "live", do: gettext("live key"), else: gettext("test key")) <>
           " " <> String.replace(mask(key), ~r/^.*••••/u, "••••")},
      key &&
        {:fact,
         if(creds["product:#{p.mode}:#{currency}"],
           do: gettext("VIP product created automatically"),
           else: gettext("the VIP product is created on the first checkout")
         )},
      p.id && {:fact, gettext("test and production are separate accounts")}
    ]
    |> Enum.filter(& &1)
  end

  defp facts(%{provider: "mercado_pago"} = p, creds, _currency) do
    token = creds["access_token"]

    [
      token && {:key, mask(token)},
      token &&
        {:fact,
         if(String.starts_with?(token, "TEST-"),
           do: gettext("test Access Token"),
           else: gettext("production Access Token")
         )},
      p.id &&
        {:fact,
         if(creds["webhook_secret"],
           do: gettext("webhook signature checked · everything confirmed on the API"),
           else: gettext("signature optional · everything is confirmed on the API")
         )}
    ]
    |> Enum.filter(& &1)
  end

  attr :provider, PaymentProvider, required: true
  attr :form, :any, required: true
  attr :test_order, :any, default: nil
  attr :currency, :string, required: true

  defp config_panel(assigns) do
    p = assigns.provider
    creds = p.credentials || %{}

    steps = [
      Map.has_key?(creds, key_field(p.provider)),
      p.checked_at != nil and p.check_error == nil,
      p.last_webhook_at != nil,
      Map.has_key?(creds, "webhook_secret") or
        (p.provider == "mercado_pago" and p.last_webhook_at != nil)
    ]

    assigns =
      assigns
      |> assign(:creds, creds)
      |> assign(:steps, steps)
      |> assign(:done, Enum.count(steps, & &1))
      |> assign(:current, Enum.find_index(steps, &(!&1)))
      |> assign(:webhook_url, Endpoint.url() <> "/webhooks/" <> p.provider)

    ~H"""
    <aside
      id={"provider-config-#{@provider.provider}"}
      aria-label={gettext("Set up %{provider}", provider: provider_name(@provider.provider))}
      class="flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] border border-base-300 bg-base-100"
    >
      <.form
        for={@form}
        id={"provider-form-#{@provider.provider}"}
        phx-submit="save-provider"
        class="flex flex-1 flex-col"
      >
        <input type="hidden" name="provider[enabled]" value={to_string(@provider.enabled)} />
        <div class="flex flex-wrap items-center gap-3 border-b border-line-soft px-[1.375rem] py-[1.125rem]">
          <span class="flex min-w-0 flex-1 flex-col gap-0.5">
            <h2 class="font-display text-xl font-semibold">
              {gettext("Set up %{provider}", provider: provider_name(@provider.provider))}
            </h2>
            <span class="text-xs text-muted">
              {gettext("%{done} of 4 steps · saved after the connection test", done: @done)}
            </span>
          </span>
          <div
            :if={@provider.provider != "stripe"}
            role="radiogroup"
            aria-label={gettext("Mode of %{provider}", provider: provider_name(@provider.provider))}
            class="vip-seg vip-seg-eng vip-seg-sm border border-line-raised !p-[3px]"
          >
            <label class="!h-[1.875rem] !px-3">
              <input
                type="radio"
                name="provider[mode]"
                value="test"
                checked={@provider.mode != "live"}
              />
              {gettext("In test")}
            </label>
            <label class="!h-[1.875rem] !px-3">
              <input
                type="radio"
                name="provider[mode]"
                value="live"
                checked={@provider.mode == "live"}
              />
              {gettext("Production")}
            </label>
          </div>
          <.link
            patch={~p"/vip-shop/settings/payments"}
            id="close-provider"
            aria-label={gettext("Close")}
            class="flex size-9 items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>

        <div class="flex flex-1 flex-col gap-3 px-[1.375rem] py-4">
          <span
            :if={note(@provider.provider)}
            class="vip-eng-box rounded-xl px-3 py-[0.5625rem] text-xs leading-[1.45]"
          >
            {note(@provider.provider)}
          </span>

          <.step
            n={1}
            done={Enum.at(@steps, 0)}
            current={@current == 0}
            title={step_one(@provider.provider)}
          >
            <span class="text-xs text-muted">{step_one_path(@provider.provider)}</span>
            <a
              href={key_link(@provider.provider)}
              target="_blank"
              rel="noopener"
              class="flex items-center gap-1 font-mono text-xs text-primary"
            >
              {key_link(@provider.provider) |> String.replace("https://", "")}
              <.icon name="hero-arrow-up-right" class="size-3" />
            </a>
          </.step>

          <.step
            n={2}
            done={Enum.at(@steps, 1)}
            current={@current == 1}
            title={step_two(@provider.provider)}
          >
            <span class="flex gap-2">
              <span class={[
                "vip-field !h-10 !px-3",
                Enum.at(@steps, 1) && "!border-[var(--vip-ok-line)]"
              ]}>
                <input
                  type="password"
                  name={"provider[credentials][#{key_field(@provider.provider)}]"}
                  id={"#{@provider.provider}-#{key_field(@provider.provider)}"}
                  value=""
                  autocomplete="off"
                  placeholder={
                    mask(@creds[key_field(@provider.provider)]) || key_placeholder(@provider.provider)
                  }
                  aria-label={step_two(@provider.provider)}
                  class="font-mono !text-xs"
                />
              </span>
              <button
                type="submit"
                id={"test-connection-#{@provider.provider}"}
                phx-disable-with={gettext("Testing...")}
                class="vip-btn vip-btn-raised !h-10 px-3.5 text-[0.8125rem]"
              >
                {gettext("Test connection")}
              </button>
            </span>
            <span :if={@provider.checked_at} class="flex items-center gap-2 text-xs text-subtle">
              <%= if @provider.check_error do %>
                <.icon name="hero-x-mark" class="size-3.5 vip-err" />
                <span><strong class="font-semibold vip-err">{gettext("Connection refused")}</strong>
                · {@provider.check_error}</span>
              <% else %>
                <.icon name="hero-check" class="size-3.5 vip-ok" />
                <span>
                  <strong class="font-semibold vip-ok">{gettext("Connection ok")}</strong>
                  · {if @provider.mode == "live",
                    do: gettext("production mode"),
                    else: gettext("test mode")} ·
                  <.vip_time id="config-checked" at={@provider.checked_at} format="ago" />
                </span>
              <% end %>
            </span>
          </.step>

          <.step
            n={3}
            done={Enum.at(@steps, 2)}
            current={@current == 2}
            title={gettext("Register the webhook")}
          >
            <:aside>
              <a
                href={webhook_link(@provider.provider)}
                target="_blank"
                rel="noopener"
                class="text-xs text-primary"
              >
                {webhook_link_label(@provider.provider)}
              </a>
            </:aside>
            <span class="flex h-10 items-center gap-2 rounded-xl border border-line-raised bg-secondary pl-3 pr-1">
              <span class="min-w-0 flex-1 truncate font-mono text-xs">{@webhook_url}</span>
              <.copy_button
                id={"copy-webhook-#{@provider.provider}"}
                value={@webhook_url}
                label={gettext("Copy URL")}
                class="h-8 rounded-full bg-base-100 px-3 text-xs"
              />
            </span>
            <span class="text-xs text-muted">{events_label(@provider.provider)}</span>
            <span class="flex flex-wrap gap-1.5">
              <span
                :for={event <- events(@provider.provider)}
                class="rounded-lg px-[0.5625rem] py-[0.3125rem] font-mono text-[0.6875rem] vip-chip-ok"
              >
                {event}
              </span>
            </span>
          </.step>

          <.step
            n={4}
            done={Enum.at(@steps, 3)}
            current={@current == 3}
            title={step_four(@provider.provider)}
          >
            <span class="flex gap-2">
              <span class="vip-field !h-10 !px-3">
                <input
                  type="password"
                  name="provider[credentials][webhook_secret]"
                  id={"#{@provider.provider}-webhook_secret"}
                  value=""
                  autocomplete="off"
                  placeholder={mask(@creds["webhook_secret"]) || "whsec_…"}
                  aria-label={step_four(@provider.provider)}
                  class="font-mono !text-xs"
                />
              </span>
              <button type="submit" class="vip-btn vip-btn-raised !h-10 px-3.5 text-[0.8125rem]">
                {gettext("Save")}
              </button>
            </span>
            <span :if={@provider.last_webhook_at} class="flex items-center gap-2 text-xs text-subtle">
              <span class="vip-dot vip-dot-ok"></span>
              <span>
                <strong class="font-semibold text-base-content">{gettext("Last webhook:")}</strong>
                <span class="font-mono text-[0.6875rem]">{@provider.last_webhook_event}</span>
                <.vip_time id="config-webhook" at={@provider.last_webhook_at} format="ago" />
                · {gettext("signature ok")}
              </span>
            </span>
          </.step>

          <span class="flex-1"></span>

          <div class="flex flex-col rounded-2xl bg-secondary">
            <div
              :if={@provider.provider == "dodo"}
              class="flex items-center gap-2.5 border-b border-base-300 px-3.5 py-[0.6875rem]"
            >
              <.icon name="hero-cube" class="size-4 text-subtle" />
              <span class="flex-1 text-xs text-subtle">
                {gettext("VIP product created automatically · open price in %{currency}",
                  currency: @currency
                )}
              </span>
              <span
                :if={@creds["product:#{@provider.mode}:#{@currency}"]}
                class="max-w-[6rem] truncate font-mono text-[0.6875rem] text-muted"
              >
                {@creds["product:#{@provider.mode}:#{@currency}"]}
              </span>
            </div>
            <div class="flex items-center gap-2.5 border-b border-base-300 px-3.5 py-[0.6875rem] last:border-b-0">
              <.icon name="hero-credit-card" class="size-4 text-subtle" />
              <span class="flex-1 text-xs text-subtle">{checkout_line(@provider.provider, @currency)}</span>
              <span
                :for={method <- methods(@provider.provider)}
                class="rounded-full bg-base-100 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-subtle"
              >
                {method}
              </span>
            </div>
            <div :if={@test_order} class="flex items-center gap-2.5 px-3.5 py-[0.6875rem]">
              <.icon name="hero-beaker" class="size-4 text-subtle" />
              <span class="flex-1 text-xs text-subtle">{gettext("Last test purchase")}</span>
              <%= case @test_order.status do %>
                <% "paid" -> %>
                  <.vip_chip tone="ok">{gettext("Paid")}</.vip_chip>
                <% "canceled" -> %>
                  <.vip_chip tone="err">{gettext("Canceled")}</.vip_chip>
                <% _other -> %>
                  <.vip_chip tone="warn">{gettext("Waiting for the payment")}</.vip_chip>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2.5 border-t border-line-soft px-[1.375rem] pb-[1.125rem] pt-3.5">
          <span class="min-w-0 flex-1 text-xs leading-[1.4] text-muted">
            <%= if @provider.enabled do %>
              {gettext(
                "%{amount} on the %{provider} checkout in %{mode}. Nothing is charged in test mode.",
                amount: money(100, @currency),
                provider: provider_name(@provider.provider),
                mode:
                  if(@provider.mode == "live", do: gettext("production"), else: gettext("test mode"))
              )}
            <% else %>
              {gettext("Turn the method on to make a test purchase.")}
            <% end %>
          </span>
          <button
            type="button"
            id={"test-purchase-#{@provider.provider}"}
            phx-click="test-purchase"
            phx-value-provider={@provider.provider}
            disabled={not @provider.enabled}
            class={["vip-btn", @provider.enabled && "vip-btn-cta"]}
          >
            {gettext("Make a test purchase")}
          </button>
        </div>
      </.form>
    </aside>
    """
  end

  attr :n, :integer, required: true
  attr :done, :boolean, required: true
  attr :current, :boolean, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :aside

  defp step(assigns) do
    ~H"""
    <div class="grid grid-cols-[1.75rem_minmax(0,1fr)] gap-3">
      <span class={[
        "flex size-[1.625rem] items-center justify-center rounded-full font-mono text-xs font-medium",
        cond do
          @done -> "vip-chip-lime"
          @current -> "bg-inverse text-on-inverse"
          true -> "border-[1.5px] border-line-strong text-subtle"
        end
      ]}>
        <.icon :if={@done} name="hero-check" class="size-3.5" />
        <span :if={!@done}>{@n}</span>
      </span>
      <span class="flex min-w-0 flex-col gap-2">
        <span class="flex items-baseline gap-2">
          <strong class="flex-1 text-sm font-semibold">{@title}</strong>
          {render_slot(@aside)}
        </span>
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  defp note("dodo"),
    do:
      gettext(
        "In Dodo, test and production are separate accounts: keys and webhooks of test mode do not work in production."
      )

  defp note("mercado_pago"),
    do:
      gettext(
        "Mercado Pago has test and production credentials in the same application: paste the Access Token of the mode you pick."
      )

  defp note(_stripe), do: nil

  defp step_one("stripe"), do: gettext("Create a restricted key")
  defp step_one("dodo"), do: gettext("Create an API key with write access")
  defp step_one("mercado_pago"), do: gettext("Create a Checkout Pro application")

  defp step_one_path("stripe"),
    do:
      gettext("Developers › API keys › Create restricted key, with only Checkout Sessions: Write")

  defp step_one_path("dodo"),
    do: gettext("Developer › API keys › turn on “Enable write access”")

  defp step_one_path("mercado_pago"),
    do: gettext("Your integrations › Create application › Checkout Pro")

  defp key_link("stripe"), do: "https://dashboard.stripe.com/apikeys"
  defp key_link("dodo"), do: "https://app.dodopayments.com/developer/api-keys"
  defp key_link("mercado_pago"), do: "https://www.mercadopago.com.br/developers/panel/app"

  defp step_two("mercado_pago"), do: gettext("Paste the Access Token")
  defp step_two(_provider), do: gettext("Paste the key")

  defp key_placeholder("stripe"), do: "rk_test_…"
  defp key_placeholder("dodo"), do: gettext("API key")
  defp key_placeholder("mercado_pago"), do: "TEST-… / APP_USR-…"

  defp step_four("mercado_pago"), do: gettext("Paste the secret signature (optional)")
  defp step_four(_provider), do: gettext("Paste the signing secret")

  defp webhook_link("stripe"), do: "https://dashboard.stripe.com/workbench/webhooks"
  defp webhook_link("dodo"), do: "https://app.dodopayments.com/developer/webhooks"
  defp webhook_link("mercado_pago"), do: "https://www.mercadopago.com.br/developers/panel/app"

  defp webhook_link_label("stripe"), do: gettext("Workbench › Webhooks")
  defp webhook_link_label("dodo"), do: gettext("Developer › Webhooks")
  defp webhook_link_label("mercado_pago"), do: gettext("Webhooks › Configure notifications")

  defp events("stripe"),
    do:
      ~w(checkout.session.completed checkout.session.async_payment_succeeded checkout.session.async_payment_failed checkout.session.expired)

  defp events("dodo"),
    do: ~w(payment.succeeded payment.failed payment.processing payment.cancelled)

  defp events("mercado_pago"), do: [gettext("Payments")]

  defp events_label("mercado_pago"), do: gettext("Tick this topic:")
  defp events_label(_provider), do: gettext("Tick these 4 events:")

  defp checkout_line("dodo", currency),
    do: gettext("Checkout in %{currency} · taxes on Dodo's side", currency: currency)

  defp checkout_line("mercado_pago", currency),
    do: gettext("Checkout Pro in %{currency}", currency: currency)

  defp checkout_line(_stripe, currency),
    do: gettext("Stripe Checkout in %{currency}", currency: currency)

  defp methods("dodo"), do: ["Pix", gettext("Card")]
  defp methods("mercado_pago"), do: ["Pix", gettext("Card"), "Boleto"]
  defp methods(_stripe), do: [gettext("Card")]
end
