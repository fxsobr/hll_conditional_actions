defmodule HllConditionalActionsWeb.VipShopLive.Overview do
  @moduledoc """
  The Loja VIP's first page (VipShop board): revenue, paid orders, the VIPs
  the shop keeps active and what waits for delivery; the packages on sale,
  the payment methods, the active coupons and the latest purchases, live.
  Rendered by `HllConditionalActionsWeb.VipShopLive.Packages` at `/vip-shop`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Coupon, Stats}

  @doc "Everything the page shows."
  @spec load() :: map()
  def load do
    packages = VipShop.list_packages()

    %{
      stats: Stats.overview(),
      packages: Enum.filter(packages, & &1.active),
      sales: Stats.package_sales(),
      providers: VipShop.list_providers(),
      share: Stats.provider_share(30),
      coupons:
        VipShop.list_coupons() |> Enum.filter(&(Coupon.state(&1) == :active)) |> Enum.take(4),
      recent: Stats.orders(bucket: :all, limit: 5),
      currency: VipShop.settings().currency || "BRL"
    }
  end

  attr :data, :map, required: true

  def overview(assigns) do
    ~H"""
    <div class="flex flex-col gap-5">
      <.kpis stats={@data.stats} />

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_28.75rem]">
        <div class="flex min-w-0 flex-col gap-5">
          <.vip_panel id="overview-packages" class="flex flex-col gap-3.5 px-6 py-[1.375rem]">
            <.vip_panel_head title={gettext("Packages on sale")}>
              <.link navigate={packages_path(@data.packages)} class="text-[0.8125rem] text-primary">
                {gettext("Manage")}
              </.link>
            </.vip_panel_head>
            <p :if={@data.packages == []} class="text-sm text-muted">
              {gettext("No package on sale yet.")}
              <.link navigate={~p"/vip-shop/packages/new"} class="text-primary">
                {gettext("Create one")}
              </.link>
            </p>
            <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <.package_card
                :for={package <- @data.packages}
                package={package}
                sales={Map.get(@data.sales, package.id, 0)}
              />
            </div>
          </.vip_panel>

          <div class="grid flex-1 gap-5 md:grid-cols-2">
            <.vip_panel id="overview-payments" class="flex flex-col gap-2.5 px-6 py-[1.375rem]">
              <h2 class="mb-1 font-display text-xl font-semibold">{gettext("Payments")}</h2>
              <.link
                :for={provider <- @data.providers}
                id={"overview-provider-#{provider.provider}"}
                navigate={~p"/vip-shop/settings/payments?provider=#{provider.provider}"}
                class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3 transition-colors hover:bg-base-300/60"
              >
                <.provider_tile provider={provider.provider} />
                <span class="flex min-w-0 flex-1 flex-col">
                  <strong class="text-sm font-semibold">{provider_name(provider.provider)}</strong>
                  <span class="truncate text-xs text-muted">
                    {provider_line(provider, @data.share)}
                  </span>
                </span>
                <.provider_mode provider={provider} />
              </.link>
            </.vip_panel>

            <.vip_panel id="overview-coupons" class="flex flex-col gap-2.5 px-6 py-[1.375rem]">
              <.vip_panel_head title={gettext("Active coupons")} class="mb-1">
                <.link navigate={~p"/vip-shop/coupons/new"} class="text-[0.8125rem] text-primary">
                  {gettext("New")}
                </.link>
              </.vip_panel_head>
              <p :if={@data.coupons == []} class="text-sm text-muted">
                {gettext("No coupon running now.")}
              </p>
              <.link
                :for={coupon <- @data.coupons}
                id={"overview-coupon-#{coupon.id}"}
                navigate={~p"/vip-shop/coupons/#{coupon.id}/edit"}
                class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3 transition-colors hover:bg-base-300/60"
              >
                <span class="rounded-lg bg-base-300 px-2.5 py-1 font-mono text-[0.8125rem]">
                  {coupon.code}
                </span>
                <span class="min-w-0 flex-1 truncate text-[0.8125rem] text-subtle">
                  {coupon_value(coupon, @data.currency)} · <.coupon_deadline coupon={coupon} />
                </span>
                <span class="font-mono text-xs text-muted">
                  {coupon.uses}/{coupon.max_uses || "∞"}
                </span>
              </.link>
            </.vip_panel>
          </div>
        </div>

        <.vip_panel id="overview-recent" class="flex flex-col gap-1.5 px-6 py-[1.375rem]">
          <.vip_panel_head title={gettext("Recent purchases")} class="mb-2.5">
            <.dot_label class="text-xs">{gettext("live")}</.dot_label>
          </.vip_panel_head>
          <p :if={@data.recent == []} class="text-sm text-muted">{gettext("No purchase yet.")}</p>
          <.recent_order
            :for={{order, index} <- Enum.with_index(@data.recent)}
            order={order}
            last={index == length(@data.recent) - 1}
          />
          <.link
            :if={@data.recent != []}
            navigate={~p"/vip-shop/purchases"}
            class="mt-auto pt-3 text-[0.8125rem] text-primary"
          >
            {gettext("See every purchase")}
          </.link>
        </.vip_panel>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp kpis(assigns) do
    assigns =
      assign(
        assigns,
        :delta,
        if(assigns.stats.revenue_before > 0,
          do:
            round(
              (assigns.stats.revenue - assigns.stats.revenue_before) * 100 /
                assigns.stats.revenue_before
            )
        )
      )

    ~H"""
    <div id="overview-kpis" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <.kpi_card id="kpi-revenue" label={gettext("Revenue in 30 days")}>
        {short_money(@stats.revenue, @stats.currency)}
        <:sub>
          <span :if={@delta && @delta >= 0} class="vip-ok">
            {gettext("↑ %{pct}% over", pct: @delta)}
            <.vip_time id="kpi-month-up" at={month_start(@stats.before_month)} format="month" />
          </span>
          <span :if={@delta && @delta < 0} class="vip-err">
            {gettext("↓ %{pct}% under", pct: abs(@delta))}
            <.vip_time id="kpi-month-down" at={month_start(@stats.before_month)} format="month" />
          </span>
          <span :if={is_nil(@delta)} class="text-muted">
            {gettext("nothing sold in")}
            <.vip_time id="kpi-month-none" at={month_start(@stats.before_month)} format="month" />
          </span>
        </:sub>
      </.kpi_card>
      <.kpi_card id="kpi-orders" label={gettext("Paid orders")}>
        {@stats.paid_orders}
        <:sub>
          <span class="text-muted">
            {ngettext("%{count} as a gift", "%{count} as gifts", @stats.gifts)}
          </span>
        </:sub>
      </.kpi_card>
      <.kpi_card id="kpi-vips" label={gettext("Active VIPs from the shop")}>
        {@stats.active_vips}
        <:sub>
          <span class="text-muted">
            {ngettext(
              "%{count} ends this week",
              "%{count} end this week",
              @stats.expiring_week
            )}
          </span>
        </:sub>
      </.kpi_card>
      <.kpi_card
        id="kpi-pending"
        label={gettext("Delivery pending")}
        warn={@stats.pending_delivery > 0}
      >
        {@stats.pending_delivery}
        <:sub>
          <span class="text-muted">
            <%= cond do %>
              <% @stats.failing_servers != [] -> %>
                {gettext("%{servers} not answering CRCON",
                  servers: @stats.failing_servers |> Enum.map(&short_server/1) |> Enum.join(", ")
                )}
              <% @stats.pending_delivery > 0 -> %>
                {gettext("being delivered now")}
              <% true -> %>
                {gettext("every VIP delivered")}
            <% end %>
          </span>
        </:sub>
      </.kpi_card>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :warn, :boolean, default: false
  slot :inner_block, required: true
  slot :sub

  defp kpi_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex min-w-0 flex-col gap-1.5 rounded-[1.375rem] bg-base-100 px-5 py-[1.125rem]",
        @warn && "border vip-warn-line"
      ]}
    >
      <span class="truncate text-[0.8125rem] text-subtle">{@label}</span>
      <strong class={[
        "font-display text-[1.75rem] font-semibold leading-tight md:text-[2rem]",
        @warn && "vip-warn"
      ]}>
        {render_slot(@inner_block)}
      </strong>
      <span class="truncate text-xs">{render_slot(@sub)}</span>
    </div>
    """
  end

  attr :package, :map, required: true
  attr :sales, :integer, required: true

  defp package_card(assigns) do
    ~H"""
    <article
      id={"package-#{@package.id}"}
      class={[
        "flex min-w-0 flex-col gap-2 rounded-[1.375rem] p-[1.125rem]",
        if(@package.highlight, do: "vip-lime-card", else: "bg-secondary")
      ]}
    >
      <span class={[
        "flex items-center justify-between gap-2 text-[0.8125rem]",
        if(@package.highlight, do: "vip-lime-muted", else: "text-subtle")
      ]}>
        {duration_label(@package.duration_days)}
        <.vip_chip :if={@package.highlight} tone="ink">{@package.highlight}</.vip_chip>
      </span>
      <strong class="truncate font-display text-xl font-semibold">{@package.name}</strong>
      <span class="flex flex-wrap items-baseline gap-2">
        <span class="font-display text-[1.875rem] font-bold leading-tight">
          {money(@package.price_cents, @package.currency)}
        </span>
        <span
          :if={@package.compare_at_cents}
          class={["text-[0.8125rem] line-through", @package.highlight && "vip-lime-faint"]}
        >
          {money(@package.compare_at_cents, @package.currency)}
        </span>
      </span>
      <span class={["text-xs", if(@package.highlight, do: "vip-lime-muted", else: "text-muted")]}>
        {ngettext("%{count} server", "%{count} servers", length(@package.servers))} · {ngettext(
          "%{count} sale",
          "%{count} sales",
          @sales
        )}
      </span>
      <div class="mt-1.5 flex items-center justify-between gap-2">
        <span
          :if={@package.highlight}
          class="inline-flex items-center gap-1.5 text-xs font-semibold"
        >
          <span class="vip-dot"></span>{gettext("On sale")}
        </span>
        <.dot_label :if={!@package.highlight} class="text-xs">{gettext("On sale")}</.dot_label>
        <.link
          navigate={~p"/vip-shop/packages/#{@package.id}/edit"}
          class={[
            "vip-btn vip-btn-sm",
            if(@package.highlight,
              do: "!border-[rgba(26,32,6,0.3)] !bg-transparent !text-[#1a2006]",
              else: "vip-btn-ghost"
            )
          ]}
        >
          {gettext("Edit")}
        </.link>
      </div>
    </article>
    """
  end

  attr :provider, :map, required: true

  @doc "The mode chip of a payment method: Produção, Teste or Desligado."
  def provider_mode(assigns) do
    ~H"""
    <%= cond do %>
      <% @provider.enabled and @provider.mode == "live" -> %>
        <.vip_chip tone="ok" class="font-bold">{gettext("Production")}</.vip_chip>
      <% @provider.enabled -> %>
        <.vip_chip tone="eng" class="font-bold">{gettext("In test")}</.vip_chip>
      <% true -> %>
        <.vip_chip>{gettext("Off")}</.vip_chip>
    <% end %>
    """
  end

  attr :order, :map, required: true
  attr :last, :boolean, default: false

  defp recent_order(assigns) do
    assigns =
      assign(assigns, :failing, assigns.order.status in ~w(partial failed))

    ~H"""
    <div
      id={"recent-#{@order.id}"}
      class={[
        "flex flex-col",
        if(@failing,
          do: "vip-warn-box gap-2.5 rounded-[1.125rem] p-3.5",
          else: ["gap-2 px-1 py-3.5", !@last && "border-b border-line-soft"]
        )
      ]}
    >
      <div class="flex items-baseline justify-between gap-3">
        <span class="min-w-0 truncate text-sm"><.order_title order={@order} /></span>
        <span class="shrink-0 font-mono text-xs text-subtle">
          {money(@order.amount_cents, @order.currency)}
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-1.5">
        <.delivery_chips order={@order} />
        <span class="flex-1"></span>
        <button
          :if={@failing}
          type="button"
          id={"recent-retry-#{@order.id}"}
          phx-click="retry"
          phx-value-id={@order.id}
          class="vip-btn vip-btn-warn h-[1.875rem] px-3 text-xs"
        >
          {gettext("Try again")}
        </button>
        <span :if={!@failing} class="text-xs text-muted">
          {provider_name(@order.provider)} ·
          <.vip_time id={"recent-at-#{@order.id}"} at={@order.inserted_at} />
        </span>
      </div>
    </div>
    """
  end

  @doc ~s("Kowalski · VIP Trimestral", or "Lima presenteou Santos" for a gift.)
  attr :order, :map, required: true

  def order_title(assigns) do
    ~H"""
    <%= if @order.gift and @order.customer do %>
      <strong class="font-semibold">{@order.customer.name || @order.customer.email}</strong>
      <span class="text-subtle">{gettext("gave")}</span>
      <strong class="font-semibold">{@order.player_name || @order.player_id}</strong>
    <% else %>
      <strong class="font-semibold">{@order.player_name || @order.player_id}</strong>
      · {@order.package_name}
    <% end %>
    """
  end

  @doc """
  The chips of an order: its servers (✓ taken, "falhou"), or its payment
  state, then the coupon and whether it extended a VIP.
  """
  attr :order, :map, required: true
  attr :compact, :boolean, default: nil

  def delivery_chips(assigns) do
    grants = Stats.latest_grants(assigns.order.grants)
    granted = Enum.count(grants, &(&1.status == "granted"))
    extras = assigns.order.coupon_code != nil or extended?(assigns.order)

    assigns =
      assigns
      |> assign(:grants, grants)
      |> assign(
        :all_granted,
        grants != [] and granted == length(grants) and
          if(is_nil(assigns.compact), do: extras, else: assigns.compact)
      )

    ~H"""
    <%= case @order.status do %>
      <% "pending" -> %>
        <.vip_chip>{gettext("Waiting for payment")}</.vip_chip>
      <% "canceled" -> %>
        <.vip_chip tone="err">{gettext("Failed")}</.vip_chip>
      <% "refunded" -> %>
        <.vip_chip tone="eng">{gettext("Refunded")}</.vip_chip>
      <% _paid -> %>
        <%= if @all_granted do %>
          <.vip_chip tone="ok">
            {ngettext("%{count} server ✓", "%{count} servers ✓", length(@grants))}
          </.vip_chip>
        <% else %>
          <.vip_chip :if={@grants == []}>{gettext("Delivering")}</.vip_chip>
          <.vip_chip :for={grant <- @grants} tone={grant_tone(grant)}>
            {grant_chip(grant)}
          </.vip_chip>
        <% end %>
    <% end %>
    <.vip_chip :if={@order.coupon_code}>{@order.coupon_code}</.vip_chip>
    <.vip_chip :if={extended?(@order)}>{gettext("extended")}</.vip_chip>
    """
  end

  defp grant_tone(%{status: "granted"}), do: "ok"
  defp grant_tone(%{status: "failed"}), do: "warn"
  defp grant_tone(_grant), do: "muted"

  defp grant_chip(%{status: "granted"} = grant), do: short_server(grant.server_name) <> " ✓"

  defp grant_chip(%{status: "failed"} = grant),
    do: gettext("%{server} failed", server: short_server(grant.server_name))

  defp grant_chip(grant), do: short_server(grant.server_name) <> " …"

  @doc """
  Whether a purchase extended a VIP the player already had: a server's new
  expiry lands more than a day past the package's days from the payment.
  """
  @spec extended?(map()) :: boolean()
  def extended?(%{duration_days: days, paid_at: %DateTime{} = paid, grants: grants})
      when is_integer(days) do
    limit = DateTime.add(paid, (days + 1) * 86_400, :second)
    Enum.any?(grants, &(&1.expires_at && DateTime.after?(&1.expires_at, limit)))
  end

  def extended?(_order), do: false

  attr :coupon, :map, required: true

  @doc ~s("vence 31 out", "sem prazo".)
  def coupon_deadline(assigns) do
    ~H"""
    <%= if @coupon.expires_at do %>
      {gettext("ends")}
      <.vip_time
        id={"coupon-ends-#{@coupon.id}-#{System.unique_integer([:positive])}"}
        at={@coupon.expires_at}
        format="date"
      />
    <% else %>
      {gettext("no deadline")}
    <% end %>
    """
  end

  @doc ~s("15%" or "R$ 5".)
  @spec coupon_value(map(), String.t()) :: String.t()
  def coupon_value(%{kind: "percent", value: value}, _currency), do: "#{value}%"
  def coupon_value(%{value: value}, currency), do: short_money(value, currency)

  @doc ~s(Money without zero cents: "R$ 4.870", "R$ 5", "R$ 16,92".)
  @spec short_money(integer(), String.t()) :: String.t()
  def short_money(cents, currency) do
    formatted = money(cents, currency)
    if rem(cents, 100) == 0, do: String.replace(formatted, ~r/[,.]00$/, ""), else: formatted
  end

  @doc ~s("30 dias", or "permanente".)
  @spec duration_label(integer() | nil) :: String.t()
  def duration_label(nil), do: gettext("permanent")
  def duration_label(days), do: ngettext("%{count} day", "%{count} days", days)

  # Midday of the month's 15th, so every timezone shows the same month.
  defp month_start(%Date{} = date),
    do: DateTime.new!(%{date | day: 15}, ~T[12:00:00], "Etc/UTC")

  defp provider_line(provider, share) do
    case Map.get(share, provider.provider) do
      nil ->
        provider_methods(provider.provider)

      pct ->
        gettext("%{methods} · %{pct}% of orders",
          methods: provider_methods(provider.provider),
          pct: pct
        )
    end
  end

  defp packages_path([first | _rest]), do: ~p"/vip-shop/packages/#{first.id}/edit"
  defp packages_path([]), do: ~p"/vip-shop/packages/new"
end
