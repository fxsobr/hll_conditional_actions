defmodule HllConditionalActionsWeb.VipShopLive.Purchases do
  @moduledoc """
  The VIP purchases (VipPurchases and MobileVipPurchases boards), updating
  live: filtered by status, payment method and period, or searched. A row
  opens into its timeline and its delivery server by server, where a
  failed server is retried, the receipt sent again or the order refunded.

  `/vip-shop/purchases/grant` opens the panel that grants VIP by hand: a
  player from CRCON's history, some days, some servers and a reason.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}
  on_mount HllConditionalActionsWeb.VipShopLive.Tabs

  import HllConditionalActionsWeb.VipShopLive.Tabs
  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Stats, Storefront}
  alias HllConditionalActionsWeb.VipShopLive.Overview

  @page 10
  @periods [{"7", 7}, {"30", 30}, {"90", 90}, {"all", nil}]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: VipShop.subscribe()

    {:ok,
     socket
     |> assign(:page_title, gettext("VIP purchases"))
     |> assign(:bucket, :all)
     |> assign(:provider, "")
     |> assign(:period, "30")
     |> assign(:search, "")
     |> assign(:searching, false)
     |> assign(:limit, @page)
     |> assign(:expanded, :auto)
     |> assign(:providers, VipShop.PaymentProvider.providers())
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    socket =
      if socket.assigns.live_action == :grant,
        do: open_grant(socket),
        else: assign(socket, :grant, nil)

    {:noreply, socket}
  end

  defp open_grant(socket) do
    servers = VipShop.shop_servers()

    assign(socket, :grant, %{
      servers: servers,
      failing: Stats.failing_servers(),
      results: [],
      query: "",
      picked: nil,
      current: nil,
      days: "30",
      custom_days: "",
      server_ids: Enum.map(servers, &to_string(&1.id)),
      reason: "",
      notify: true,
      stacking: VipShop.settings().stacking
    })
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(:provider, params["provider"] || socket.assigns.provider)
      |> assign(:period, params["period"] || socket.assigns.period)
      |> assign(:search, params["search"] || socket.assigns.search)
      |> assign(:limit, @page)

    {:noreply, load(socket)}
  end

  def handle_event("bucket", %{"bucket" => bucket}, socket) do
    bucket =
      Enum.find(
        [:all, :paid, :pending, :failed, :refunded, :delivery],
        :all,
        &(to_string(&1) == bucket)
      )

    {:noreply, socket |> assign(bucket: bucket, limit: @page, expanded: :auto) |> load()}
  end

  def handle_event("toggle-search", _params, socket) do
    searching = not socket.assigns.searching
    socket = assign(socket, :searching, searching)
    socket = if searching, do: socket, else: socket |> assign(:search, "") |> load()
    {:noreply, socket}
  end

  def handle_event("more", _params, socket),
    do: {:noreply, socket |> update(:limit, &(&1 + @page)) |> load()}

  def handle_event("expand", %{"id" => id}, socket) do
    id = String.to_integer(id)
    current = expanded_id(socket.assigns)
    {:noreply, socket |> assign(:expanded, if(current == id, do: nil, else: id)) |> load_detail()}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    %{order_id: String.to_integer(id)}
    |> HllConditionalActions.Workers.FulfillVipOrder.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, gettext("Granting the VIP again."))}
  end

  def handle_event("resend", %{"id" => id}, socket) do
    order = VipShop.get_order(String.to_integer(id))

    if order.customer && order.customer.email do
      :ok = VipShop.resend_receipt(order)
      {:noreply, put_flash(socket, :info, gettext("Receipt sent again."))}
    else
      {:noreply, put_flash(socket, :error, gettext("This order has no customer email."))}
    end
  end

  def handle_event("refund", %{"id" => id}, socket) do
    order = VipShop.get_order(String.to_integer(id))

    case VipShop.refund_order(order, actor(socket)) do
      {:ok, _order} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Order marked refunded and its VIP removed. Return the money at the provider.")
         )
         |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Only a paid order can be refunded."))}
    end
  end

  # ── Manual grant ──

  def handle_event("grant-change", params, socket) do
    grant = socket.assigns.grant
    query = String.trim(params["q"] || "")

    results =
      cond do
        query == grant.query -> grant.results
        grant.picked -> []
        typed_player_id(query) -> []
        true -> search(query)
      end

    grant = %{
      grant
      | query: query,
        results: results,
        days: params["days"] || grant.days,
        custom_days: params["custom_days"] || grant.custom_days,
        server_ids: List.wrap(params["server_ids"]) |> Enum.reject(&(&1 == "")),
        reason: params["reason"] || "",
        notify: params["notify"] == "true"
    }

    {:noreply, assign(socket, :grant, grant)}
  end

  def handle_event("pick-player", %{"id" => id, "name" => name}, socket) do
    current = VipShop.current_vip(id)

    {:noreply,
     update(socket, :grant, fn grant ->
       %{grant | picked: %{id: id, name: name}, current: current, results: [], query: ""}
     end)}
  end

  def handle_event("unpick-player", _params, socket),
    do: {:noreply, update(socket, :grant, &%{&1 | picked: nil, current: nil})}

  def handle_event("grant", params, socket) do
    socket = elem(handle_event("grant-change", params, socket), 1)
    grant = socket.assigns.grant

    {player_id, player_name} =
      case grant.picked do
        %{id: id, name: name} -> {id, name}
        nil -> {typed_player_id(grant.query), nil}
      end

    result =
      VipShop.grant_vip(%{
        player_id: player_id,
        player_name: player_name,
        duration_days: grant_days(grant),
        server_ids: grant.server_ids,
        reason: grant.reason,
        admin: actor(socket)
      })

    case result do
      {:ok, order} ->
        if grant.notify, do: note_order(order, grant.reason)

        {:noreply,
         socket
         |> put_flash(:info, gettext("VIP is being granted."))
         |> load()
         |> push_patch(to: ~p"/vip-shop/purchases")}

      {:error, :no_server} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Pick a player or type a player ID."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:vip_order, _order}, socket), do: {:noreply, load(socket)}

  defp note_order(order, ""), do: Storefront.put_order_note(order, gettext("Enjoy your VIP!"))
  defp note_order(order, reason), do: Storefront.put_order_note(order, reason)

  defp search(query) when byte_size(query) < 2, do: []

  defp search(query) do
    case VipShop.search_players(query) do
      {:ok, results} -> Enum.take(results, 6)
      {:error, _reason} -> []
    end
  end

  # A Steam id or a Windows store id typed in the search field.
  defp typed_player_id(query) do
    if query =~ ~r/^(\d{17}|[0-9a-f]{32})$/i, do: query, else: nil
  end

  defp grant_days(%{days: "custom", custom_days: text}) do
    case Integer.parse(text || "") do
      {days, ""} when days > 0 -> days
      _other -> nil
    end
  end

  defp grant_days(%{days: "forever"}), do: nil
  defp grant_days(%{days: days}), do: String.to_integer(days)

  defp actor(socket), do: socket.assigns.current_user.name || socket.assigns.current_user.username

  # ── Data ───────────────────────────────────────────────────────────────────

  defp filter_opts(assigns) do
    [
      provider: assigns.provider,
      days: Enum.find_value(@periods, fn {key, days} -> key == assigns.period && days end),
      search: assigns.search
    ]
  end

  defp load(socket) do
    filters = filter_opts(socket.assigns)
    orders = Stats.orders([bucket: socket.assigns.bucket, limit: socket.assigns.limit] ++ filters)

    socket
    |> assign(:orders, orders)
    |> assign(:counts, Stats.bucket_counts(filters))
    |> load_detail()
  end

  # The open row: the one clicked, or at first the first order waiting for
  # a server, as on the board.
  defp expanded_id(%{expanded: :auto, orders: orders}) do
    Enum.find_value(orders, fn order -> order.status in ~w(partial failed) && order.id end)
  end

  defp expanded_id(%{expanded: id}), do: id

  defp load_detail(socket) do
    case expanded_id(socket.assigns) do
      nil -> assign(socket, :detail, nil)
      id -> assign(socket, :detail, %{id: id, next_retry: Stats.next_retry(id)})
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :open, expanded_id(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Community")}
      greeting={gettext("Purchases")}
      greeting_eyebrow={gettext("Community · VIP shop")}
      scope={false}
    >
      <:actions>
        <.open_shop_link />
        <.link
          id="grant-button"
          patch={~p"/vip-shop/purchases/grant"}
          aria-expanded={to_string(@grant != nil)}
          class={[
            "vip-btn hidden md:inline-flex",
            if(@grant,
              do: "vip-btn-raised !border-line-strong pl-4 font-semibold",
              else: "vip-btn-cta"
            )
          ]}
        >
          <.icon name="hero-plus" class="size-[1.125rem]" />{gettext("Grant manually")}
        </.link>
        <.link
          id="grant-button-mobile"
          patch={~p"/vip-shop/purchases/grant"}
          class="vip-btn vip-btn-raised h-11 !border-line-strong px-4 pl-3 font-semibold md:hidden"
        >
          <.icon name="hero-plus" class="size-[1.125rem] text-primary" />{gettext("Grant")}
        </.link>
      </:actions>

      <.tabs current={:purchases} nav={@vip_nav} />

      <div class={[
        "grid gap-5",
        @grant && "xl:grid-cols-[minmax(0,1fr)_22.5rem]"
      ]}>
        <.vip_panel
          id="orders-panel"
          label={gettext("Orders")}
          class={["flex min-h-[40rem] flex-col overflow-hidden", @grant && "hidden xl:flex"]}
        >
          <.filters
            bucket={@bucket}
            counts={@counts}
            provider={@provider}
            providers={@providers}
            period={@period}
            search={@search}
            searching={@searching}
          />

          <div
            role="row"
            class="hidden grid-cols-[5.25rem_minmax(0,1fr)_6.5rem_7.25rem_minmax(0,14.5rem)_3.875rem] gap-3 border-b border-line-soft px-5 py-3 text-xs text-muted md:grid"
          >
            <span role="columnheader">{gettext("Order number")}</span>
            <span role="columnheader">{gettext("Player and package")}</span>
            <span role="columnheader">{gettext("Amount")}</span>
            <span role="columnheader">{gettext("Order status")}</span>
            <span role="columnheader">{gettext("Delivery")}</span>
            <span role="columnheader" class="text-right">{gettext("When")}</span>
          </div>

          <div id="purchases" class="flex flex-col">
            <p
              :if={@orders == []}
              id="purchases-empty"
              class="px-5 py-10 text-center text-sm text-muted"
            >
              {gettext("No purchase matches these filters.")}
            </p>
            <.order_row
              :for={{order, index} <- Enum.with_index(@orders)}
              order={order}
              open={order.id == @open}
              detail={@detail}
              last={index == length(@orders) - 1}
            />
          </div>

          <span class="flex-1"></span>
          <div class="flex items-center gap-2.5 border-t border-line-soft px-5 py-3 text-xs text-muted">
            <span class="flex-1">
              {gettext("Showing %{shown} of %{total} orders",
                shown: length(@orders),
                total: Map.get(@counts, @bucket, 0)
              )}
            </span>
            <button
              :if={length(@orders) < Map.get(@counts, @bucket, 0)}
              type="button"
              id="load-more"
              phx-click="more"
              class="vip-btn vip-btn-raised vip-btn-sm !h-8 px-3.5"
            >
              {gettext("Load more")}
            </button>
          </div>
        </.vip_panel>

        <.grant_panel :if={@grant} grant={@grant} current_user={@current_user} />
      </div>
    </Layouts.app>
    """
  end

  attr :bucket, :atom, required: true
  attr :counts, :map, required: true
  attr :provider, :string, required: true
  attr :providers, :list, required: true
  attr :period, :string, required: true
  attr :search, :string, required: true
  attr :searching, :boolean, required: true

  defp filters(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5 border-b border-line-soft px-4 py-4 md:flex-row md:items-center md:px-5">
      <div
        role="radiogroup"
        aria-label={gettext("Status")}
        class="-mx-4 flex gap-1.5 overflow-x-auto px-4 md:mx-0 md:px-0"
      >
        <.bucket_chip id="bucket-all" key={:all} bucket={@bucket} count={@counts.all}>
          {gettext("All orders")}
        </.bucket_chip>
        <.bucket_chip
          id="bucket-delivery"
          key={:delivery}
          bucket={@bucket}
          count={@counts.delivery}
          tone="warn"
          class="md:hidden"
        >
          {gettext("Delivery pending")}
        </.bucket_chip>
        <.bucket_chip
          id="bucket-paid"
          key={:paid}
          bucket={@bucket}
          count={@counts.paid}
          class="hidden md:inline-flex"
        >
          {gettext("Paid")}
        </.bucket_chip>
        <.bucket_chip
          id="bucket-pending"
          key={:pending}
          bucket={@bucket}
          count={@counts.pending}
          class="md:order-none order-last"
        >
          {gettext("Waiting")}
        </.bucket_chip>
        <.bucket_chip
          id="bucket-failed"
          key={:failed}
          bucket={@bucket}
          count={@counts.failed}
          tone="err"
        >
          {gettext("Failed")}
        </.bucket_chip>
        <.bucket_chip
          id="bucket-refunded"
          key={:refunded}
          bucket={@bucket}
          count={@counts.refunded}
          class="hidden md:inline-flex"
        >
          {gettext("Refunded")}
        </.bucket_chip>
      </div>
      <span class="hidden flex-1 md:block"></span>
      <form
        id="purchase-filters"
        phx-change="filter"
        phx-submit="filter"
        class="hidden flex-wrap items-center gap-1.5 md:flex"
      >
        <label class="vip-filter relative !h-[2.125rem] cursor-pointer bg-secondary !text-xs">
          <span class="text-muted">{gettext("Provider")}</span>
          <select
            name="provider"
            class="cursor-pointer appearance-none border-0 bg-transparent p-0 pr-4 text-xs [field-sizing:content] focus:ring-0"
          >
            <option value="">{gettext("All providers")}</option>
            <option :for={p <- @providers ++ ["manual"]} value={p} selected={p == @provider}>
              {provider_name(p)}
            </option>
          </select>
          <.icon name="hero-chevron-down" class="pointer-events-none absolute right-3 size-3.5" />
        </label>
        <label class="vip-filter relative !h-[2.125rem] cursor-pointer bg-secondary !text-xs">
          <span class="text-muted">{gettext("Period")}</span>
          <select
            name="period"
            class="cursor-pointer appearance-none border-0 bg-transparent p-0 pr-4 text-xs [field-sizing:content] focus:ring-0"
          >
            <option value="7" selected={@period == "7"}>{gettext("7 days")}</option>
            <option value="30" selected={@period == "30"}>{gettext("30 days")}</option>
            <option value="90" selected={@period == "90"}>{gettext("90 days")}</option>
            <option value="all" selected={@period == "all"}>{gettext("All time")}</option>
          </select>
          <.icon name="hero-chevron-down" class="pointer-events-none absolute right-3 size-3.5" />
        </label>
        <input
          :if={@searching}
          type="search"
          name="search"
          id="purchase-search"
          value={@search}
          phx-debounce="300"
          phx-mounted={JS.focus()}
          placeholder={gettext("Player, customer or order")}
          class="vip-field !h-[2.125rem] w-48 !rounded-full !text-xs"
        />
        <button
          type="button"
          id="toggle-search"
          phx-click="toggle-search"
          aria-label={gettext("Search orders")}
          class="flex size-[2.125rem] items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle"
        >
          <.icon
            name={if @searching, do: "hero-x-mark", else: "hero-magnifying-glass"}
            class="size-4"
          />
        </button>
      </form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :key, :atom, required: true
  attr :bucket, :atom, required: true
  attr :count, :integer, required: true
  attr :tone, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp bucket_chip(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      id={@id}
      aria-checked={to_string(@key == @bucket)}
      aria-current={@key == @bucket && "true"}
      phx-click="bucket"
      phx-value-bucket={@key}
      class={[
        "vip-filter !h-10 !px-3.5 !text-[0.8125rem] md:!h-[2.125rem] md:!px-3 md:!text-xs",
        @key != @bucket && "bg-secondary md:bg-secondary",
        @key != @bucket && @tone == "warn" && "vip-filter-warn font-semibold",
        @key != @bucket && @tone == "err" && "vip-filter-err font-semibold",
        @key == @bucket && "font-semibold",
        @class
      ]}
    >
      {render_slot(@inner_block)} <span class="font-mono text-xs">{@count}</span>
    </button>
    """
  end

  attr :order, :map, required: true
  attr :open, :boolean, default: false
  attr :detail, :map, default: nil
  attr :last, :boolean, default: false

  defp order_row(assigns) do
    assigns =
      assigns
      |> assign(:grants, Stats.latest_grants(assigns.order.grants))
      |> assign(:attention, assigns.order.status in ~w(partial failed))

    ~H"""
    <div
      id={"purchase-#{@order.id}"}
      class={[
        @open && "mx-2.5 my-2 overflow-hidden rounded-[1.25rem] border bg-secondary",
        @open && if(@attention, do: "vip-warn-line", else: "border-line-raised"),
        !@open && !@last && "border-b border-line-soft"
      ]}
    >
      <%!-- Wide screens: a row of the table. --%>
      <button
        type="button"
        phx-click="expand"
        phx-value-id={@order.id}
        aria-expanded={to_string(@open)}
        class={[
          "hidden w-full grid-cols-[5.25rem_minmax(0,1fr)_6.5rem_7.25rem_minmax(0,14.5rem)_3.875rem] items-center gap-3 py-3 text-left md:grid",
          if(@open, do: "px-2.5", else: "px-5 hover:bg-secondary/60")
        ]}
      >
        <span class="flex items-center gap-1 font-mono text-xs text-subtle">
          <.icon
            name={if @open, do: "hero-chevron-down", else: "hero-chevron-right"}
            class={["size-3.5", !@open && "opacity-0"]}
          />V-{@order.id}
        </span>
        <span class="flex min-w-0 flex-col gap-0.5">
          <strong class="truncate text-sm font-semibold">
            <.title order={@order} />
          </strong>
          <span class="truncate text-xs text-muted">
            {@order.package_name}<span :if={@order.coupon_code}> · <span class="font-mono">{@order.coupon_code}</span></span>
          </span>
        </span>
        <span class="flex min-w-0 flex-col gap-0.5">
          <span class={[
            "font-mono text-[0.8125rem]",
            @order.status == "refunded" && "text-subtle line-through"
          ]}>
            {money(@order.amount_cents, @order.currency)}
          </span>
          <span class="truncate text-[0.6875rem] text-muted">{paid_with(@order)}</span>
        </span>
        <span><.status_chip order={@order} /></span>
        <span class="flex min-w-0 flex-wrap gap-1"><.delivery order={@order} grants={@grants} /></span>
        <span class="text-right font-mono text-xs text-subtle">
          <.vip_time id={"order-at-#{@order.id}"} at={@order.inserted_at} />
        </span>
      </button>

      <%!-- Phones: two lines, as on MobileVipPurchases. --%>
      <button
        type="button"
        phx-click="expand"
        phx-value-id={@order.id}
        aria-expanded={to_string(@open)}
        class={[
          "flex w-full flex-col justify-center gap-[0.1875rem] py-2 text-left md:hidden",
          if(@open, do: "px-4 pt-4", else: "min-h-[3.75rem] px-4")
        ]}
      >
        <span :if={@open} class="flex w-full items-center gap-2">
          <strong class="min-w-0 flex-1 truncate font-display text-[1.0625rem] font-semibold">
            <.title order={@order} />
          </strong>
          <.status_chip order={@order} />
        </span>
        <span :if={@open} class="truncate text-xs text-muted">
          <span class="font-mono text-[0.6875rem] text-subtle">V-{@order.id}</span>
          · {@order.package_name} ·
          <span class="font-mono text-[0.6875rem] text-subtle">
            {money(@order.amount_cents, @order.currency)}
          </span>
          · {paid_with(@order)} · <.vip_time id={"order-at-o-#{@order.id}"} at={@order.inserted_at} />
        </span>
        <span :if={!@open} class="flex w-full items-center gap-2">
          <strong class="min-w-0 flex-1 truncate text-sm font-semibold"><.title order={@order} /></strong>
          <span class="font-mono text-[0.8125rem]">{money(@order.amount_cents, @order.currency)}</span>
        </span>
        <span :if={!@open} class="flex w-full items-center gap-2">
          <span class="min-w-0 flex-1 truncate text-xs text-muted">
            <span class="font-mono text-[0.6875rem]">V-{@order.id}</span>
            · {@order.coupon_code || @order.package_name} ·
            <.vip_time id={"order-at-m-#{@order.id}"} at={@order.inserted_at} />
          </span>
          <.status_chip order={@order} grants={@grants} compact />
        </span>
      </button>

      <.order_detail :if={@open} order={@order} grants={@grants} detail={@detail} />
    </div>
    """
  end

  attr :order, :map, required: true

  defp title(assigns) do
    ~H"""
    <%= if @order.gift and @order.customer do %>
      {@order.customer.name || @order.customer.email}
      <span class="font-normal text-muted">{gettext("gave")}</span>
      {@order.player_name || @order.player_id}
    <% else %>
      {@order.player_name || @order.player_id}
    <% end %>
    """
  end

  attr :order, :map, required: true
  attr :grants, :list, default: []
  attr :compact, :boolean, default: false

  defp status_chip(assigns) do
    assigns =
      assign(assigns, :granted, Enum.count(assigns.grants, &(&1.status == "granted")))

    ~H"""
    <%= case @order.status do %>
      <% "pending" -> %>
        <span class="vip-chip bg-base-300">{gettext("Waiting")}</span>
      <% "canceled" -> %>
        <.vip_chip tone="err">{gettext("Failed")}</.vip_chip>
      <% "refunded" -> %>
        <.vip_chip tone="eng">{gettext("Refunded")}</.vip_chip>
      <% _paid -> %>
        <.vip_chip tone="ok">
          {gettext("Paid")}<span :if={@compact and @grants != []}> · {@granted}/{length(@grants)}</span>
        </.vip_chip>
    <% end %>
    """
  end

  attr :order, :map, required: true
  attr :grants, :list, required: true

  defp delivery(assigns) do
    ~H"""
    <%= case @order.status do %>
      <% "pending" -> %>
        <span class="text-xs text-muted">{gettext("waiting for the payment")}</span>
      <% "canceled" -> %>
        <span class="truncate text-xs text-muted">{@order.error || gettext("payment refused")}</span>
      <% "refunded" -> %>
        <span class="truncate text-xs text-muted">
          {ngettext(
            "VIP removed from %{count} server",
            "VIP removed from %{count} servers",
            length(@grants)
          )}
        </span>
      <% _paid -> %>
        <Overview.delivery_chips
          order={%{@order | coupon_code: nil, grants: @grants}}
          compact={@order.coupon_code != nil or @order.gift}
        />
    <% end %>
    """
  end

  attr :order, :map, required: true
  attr :grants, :list, required: true
  attr :detail, :map, default: nil

  defp order_detail(assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(0,1fr)] gap-4 px-4 pb-4 pt-1 md:grid-cols-2">
      <div class="hidden flex-col rounded-2xl bg-base-100 px-4 py-3.5 md:flex">
        <span class="mb-2 text-xs uppercase tracking-[0.06em] text-muted">{gettext("Timeline")}</span>
        <div
          :for={{event, index} <- Enum.with_index(order_timeline(@order))}
          class="grid grid-cols-[3.875rem_0.75rem_minmax(0,1fr)] gap-2 py-1 text-xs"
        >
          <.vip_time
            id={"timeline-#{@order.id}-#{index}"}
            at={event.at}
            format="clock"
            class="font-mono text-muted"
          />
          <span class={[
            "mt-1 size-2 rounded-full",
            case event.tone do
              :ok -> "vip-dot-ok"
              :warn -> "bg-[var(--vip-warn-fill)]"
              :err -> "bg-error"
              _muted -> "bg-muted"
            end
          ]}></span>
          <span class={[
            case event.tone do
              :ok -> "text-base-content"
              :warn -> "vip-warn"
              :err -> "vip-err"
              _muted -> "text-subtle"
            end
          ]}>
            {event.text}
            <span :if={event[:ref]} class="font-mono text-muted">{event.ref}</span>
          </span>
        </div>
      </div>

      <div class="flex flex-col gap-2">
        <span class="px-1 pt-0 text-[0.6875rem] uppercase tracking-[0.06em] text-muted md:pt-3.5 md:text-xs">
          {gettext("Delivery per server")}
        </span>
        <p :if={@grants == [] and @order.status in ~w(paid)} class="px-1 text-xs text-muted">
          {gettext("Being delivered now.")}
        </p>
        <p
          :if={@grants == [] and @order.status in ~w(pending canceled)}
          class="px-1 text-xs text-muted"
        >
          {gettext("Delivery starts once the payment is confirmed.")}
        </p>
        <div
          :for={grant <- @grants}
          id={"grant-#{@order.id}-#{grant.id}"}
          class={[
            "flex min-h-12 items-center gap-2.5 rounded-[0.875rem] px-3 py-2.5",
            if(grant.status == "failed", do: "vip-warn-box", else: "bg-base-100")
          ]}
        >
          <span class={[
            "flex size-[1.625rem] shrink-0 items-center justify-center rounded-full text-sm font-bold",
            case grant.status do
              "granted" -> "vip-chip-ok"
              "failed" -> "vip-chip-warn"
              _other -> "bg-base-300 text-subtle"
            end
          ]}>
            <%= case grant.status do %>
              <% "granted" -> %>
                <.icon name="hero-check" class="size-3.5" />
              <% "failed" -> %>
                !
              <% _other -> %>
                <.icon name="hero-minus" class="size-3.5" />
            <% end %>
          </span>
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="truncate text-[0.8125rem] font-semibold">{grant.server_name}</span>
            <span class={[
              "text-[0.6875rem] md:text-[0.6875rem]",
              if(grant.status == "failed", do: "text-subtle", else: "text-muted")
            ]}>
              <.grant_line grant={grant} order={@order} detail={@detail} />
            </span>
          </span>
          <button
            :if={grant.status == "failed"}
            type="button"
            phx-click="retry"
            phx-value-id={@order.id}
            class="vip-btn vip-btn-warn hidden h-[1.875rem] px-3 text-xs md:inline-flex"
          >
            {gettext("Try again")}
          </button>
        </div>

        <div class="mt-0.5 flex gap-2">
          <button
            :if={Enum.any?(@grants, &(&1.status == "failed"))}
            type="button"
            phx-click="retry"
            phx-value-id={@order.id}
            class="vip-btn vip-btn-cta h-11 min-w-0 flex-1 px-3 text-sm md:hidden"
          >
            <.icon name="hero-arrow-path" class="size-4" />{gettext("Try %{server} now",
              server:
                @grants
                |> Enum.find(&(&1.status == "failed"))
                |> then(&short_server(&1.server_name))
            )}
          </button>
          <button
            :if={@order.status in ~w(paid fulfilled partial failed) and @order.customer}
            type="button"
            id={"resend-#{@order.id}"}
            phx-click="resend"
            phx-value-id={@order.id}
            class="vip-btn vip-btn-ghost h-11 shrink-0 px-3.5 text-[0.8125rem] md:h-[2.125rem] md:flex-1 md:shrink md:text-xs"
          >
            {gettext("Resend e-mail")}
          </button>
          <button
            :if={@order.status in ~w(paid fulfilled partial failed) and @order.provider != "manual"}
            type="button"
            id={"refund-#{@order.id}"}
            phx-click="refund"
            phx-value-id={@order.id}
            data-confirm={
              gettext(
                "Mark this order refunded and remove its VIP from every server? Return the money at the provider yourself."
              )
            }
            class="vip-btn vip-btn-ghost hidden h-[2.125rem] flex-1 text-xs text-[var(--vip-danger-text)] md:inline-flex"
          >
            {gettext("Refund")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :grant, :map, required: true
  attr :order, :map, required: true
  attr :detail, :map, default: nil

  defp grant_line(assigns) do
    assigns = assign(assigns, :attempts, Stats.attempts(assigns.order.grants, assigns.grant))

    ~H"""
    <%= case @grant.status do %>
      <% "granted" -> %>
        {gettext("delivered")}
        <.vip_time id={"grant-at-#{@grant.id}"} at={@grant.updated_at} format="datetime" /> ·
        <%= if @grant.expires_at do %>
          {gettext("until")}
          <.vip_time id={"grant-until-#{@grant.id}"} at={@grant.expires_at} format="date" />
        <% else %>
          {gettext("permanent")}
        <% end %>
      <% "failed" -> %>
        {gettext("CRCON down since")}
        <.vip_time
          id={"grant-failed-#{@grant.id}"}
          at={first_failure(@order.grants, @grant)}
          format="datetime"
        /> · {ngettext("%{count} attempt", "%{count} attempts", @attempts)}
        <%= if @detail && @detail.next_retry do %>
          · {gettext("next at")}
          <.vip_time id={"grant-next-#{@grant.id}"} at={@detail.next_retry} format="datetime" />
        <% end %>
      <% "removed" -> %>
        {gettext("VIP removed")}
      <% _pending -> %>
        {gettext("waiting")}
    <% end %>
    """
  end

  defp first_failure(grants, grant) do
    grants
    |> Enum.filter(&(&1.status == "failed" and &1.server_id == grant.server_id))
    |> Enum.map(& &1.inserted_at)
    |> Enum.min(DateTime, fn -> grant.inserted_at end)
  end

  # What happened to an order, in order, from what it recorded.
  defp order_timeline(order) do
    grants =
      order.grants
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&grant_step/1)
      |> Enum.reject(&is_nil/1)

    ([created_step(order)] ++ paid_steps(order) ++ grants ++ tail_steps(order))
    |> Enum.sort_by(& &1.at, DateTime)
  end

  defp created_step(%{provider: "manual"} = order) do
    %{
      at: order.inserted_at,
      text:
        gettext("Granted by %{admin}", admin: order.granted_by || "?") <>
          if(order.reason, do: " · " <> order.reason, else: ""),
      tone: :muted
    }
  end

  defp created_step(order) do
    %{
      at: order.inserted_at,
      text:
        gettext("Order created · %{provider} checkout", provider: provider_name(order.provider)),
      tone: :muted
    }
  end

  defp paid_steps(%{provider: "manual"}), do: []
  defp paid_steps(%{paid_at: nil}), do: []

  defp paid_steps(order) do
    [
      %{
        at: order.paid_at,
        text: gettext("Payment approved"),
        ref:
          order.provider_ref &&
            "#{String.downcase(provider_initials(order.provider))} #{order.provider_ref}",
        tone: :ok
      }
    ]
  end

  defp grant_step(%{status: "granted"} = grant) do
    %{
      at: grant.updated_at,
      text:
        if(grant.expires_at,
          do:
            gettext("VIP on %{server} until %{date}",
              server: grant.server_name,
              date: Calendar.strftime(grant.expires_at, "%d/%m")
            ),
          else: gettext("Permanent VIP on %{server}", server: grant.server_name)
        ),
      tone: :ok
    }
  end

  defp grant_step(%{status: "failed"} = grant) do
    %{
      at: grant.updated_at,
      text: gettext("%{server} did not answer", server: grant.server_name),
      tone: :warn
    }
  end

  defp grant_step(%{status: "removed"} = grant) do
    %{
      at: grant.updated_at,
      text: gettext("VIP removed from %{server}", server: grant.server_name),
      tone: :muted
    }
  end

  defp grant_step(_grant), do: nil

  defp tail_steps(order) do
    [
      order.receipt_sent_at &&
        %{
          at: order.receipt_sent_at,
          text: gettext("“Purchase approved” e-mail sent"),
          tone: :muted
        },
      order.status == "canceled" &&
        %{at: order.updated_at, text: order.error || gettext("Payment refused"), tone: :err},
      order.refunded_at &&
        %{
          at: order.refunded_at,
          text: gettext("Refunded by %{admin}", admin: order.refunded_by || "?"),
          tone: :muted
        }
    ]
    |> Enum.filter(& &1)
  end

  defp paid_with(%{provider: "manual"} = order),
    do: gettext("Given by %{admin}", admin: order.granted_by || "?")

  defp paid_with(order), do: provider_name(order.provider)

  # ── Grant panel ────────────────────────────────────────────────────────────

  attr :grant, :map, required: true
  attr :current_user, :map, required: true

  defp grant_panel(assigns) do
    days = grant_days(assigns.grant)

    base =
      if(assigns.grant.stacking == "extend" and match?(%DateTime{}, assigns.grant.current),
        do: assigns.grant.current,
        else: DateTime.utc_now(:second)
      )

    assigns =
      assigns
      |> assign(:until, days && DateTime.add(base, days * 86_400, :second))
      |> assign(:permanent, is_nil(days) or assigns.grant.current == :permanent)

    ~H"""
    <.vip_panel
      id="grant-panel"
      label={gettext("Grant VIP manually")}
      class="flex flex-col gap-4 border border-line-strong p-[1.375rem]"
    >
      <div class="flex items-center">
        <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Grant manually")}</h2>
        <.link
          patch={~p"/vip-shop/purchases"}
          aria-label={gettext("Close")}
          class="flex size-8 items-center justify-center rounded-full bg-secondary text-subtle"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>

      <form
        id="grant-form"
        phx-change="grant-change"
        phx-submit="grant"
        class="flex flex-1 flex-col gap-4"
      >
        <div class="flex flex-col gap-1.5">
          <label for="grant-player" class="text-[0.8125rem] text-subtle">{gettext("Player")}</label>
          <span :if={!@grant.picked} class="vip-field text-muted">
            <.icon name="hero-magnifying-glass" class="size-4" />
            <input
              type="text"
              id="grant-player"
              name="q"
              value={@grant.query}
              phx-debounce="400"
              autocomplete="off"
              placeholder={gettext("Name or player ID")}
              class="!text-base-content"
            />
          </span>
          <input :if={@grant.picked} type="hidden" name="q" value="" />
          <ul
            :if={@grant.results != []}
            id="grant-results"
            class="flex flex-col overflow-hidden rounded-[0.875rem] border border-line-raised"
          >
            <li :for={result <- @grant.results}>
              <button
                type="button"
                phx-click="pick-player"
                phx-value-id={result.player_id}
                phx-value-name={result.name}
                class="flex w-full items-center justify-between gap-2 px-3 py-2.5 text-left text-sm hover:bg-secondary"
              >
                <span class="truncate">{result.name}</span>
                <span class="font-mono text-[0.6875rem] text-muted">{result.player_id}</span>
              </button>
            </li>
          </ul>
          <div
            :if={@grant.picked}
            id="grant-picked"
            class="flex items-center gap-2.5 rounded-[0.875rem] bg-secondary px-3 py-2.5 vip-selected"
          >
            <span class="flex size-[2.125rem] shrink-0 items-center justify-center rounded-[0.6875rem] bg-allies/14 text-xs font-bold text-allies">
              {initials(@grant.picked.name)}
            </span>
            <span class="flex min-w-0 flex-1 flex-col gap-0.5">
              <strong class="truncate text-sm font-semibold">{@grant.picked.name}</strong>
              <span class="truncate font-mono text-[0.6875rem] text-muted">{@grant.picked.id}</span>
            </span>
            <%= case @grant.current do %>
              <% %DateTime{} = until -> %>
                <.vip_chip tone="warn" class="px-2 py-[0.1875rem]">
                  {gettext("VIP until")} <.vip_time id="grant-current" at={until} format="date" />
                </.vip_chip>
              <% :permanent -> %>
                <.vip_chip tone="warn" class="px-2 py-[0.1875rem]">
                  {gettext("Permanent VIP")}
                </.vip_chip>
              <% nil -> %>
                <.vip_chip class="px-2 py-[0.1875rem]">{gettext("No VIP")}</.vip_chip>
            <% end %>
            <button
              type="button"
              phx-click="unpick-player"
              aria-label={gettext("Change player")}
              class="text-muted hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <fieldset class="flex flex-col gap-2">
          <legend class="mb-2 text-[0.8125rem] text-subtle">{gettext("Duration")}</legend>
          <div role="radiogroup" aria-label={gettext("Duration")} class="grid grid-cols-3 gap-1.5">
            <label
              :for={
                {value, label} <- [
                  {"30", gettext("30 days")},
                  {"90", gettext("90 days")},
                  {"custom", gettext("Other duration")}
                ]
              }
              class={[
                "flex h-10 cursor-pointer items-center justify-center rounded-xl text-[0.8125rem]",
                if(@grant.days == value,
                  do: "vip-ok-box font-semibold",
                  else: "border border-line-raised bg-secondary text-subtle"
                )
              ]}
            >
              <input
                type="radio"
                name="days"
                value={value}
                checked={@grant.days == value}
                class="sr-only"
              />
              {label}
            </label>
          </div>
          <span :if={@grant.days == "custom"} class="vip-field">
            <input
              type="number"
              min="1"
              max="3650"
              name="custom_days"
              id="grant-custom-days"
              value={@grant.custom_days}
              placeholder="60"
              class="font-mono"
            />
            <span class="text-[0.8125rem] text-muted">{gettext("days")}</span>
          </span>
        </fieldset>

        <fieldset class="flex flex-col gap-1.5">
          <legend class="mb-2 text-[0.8125rem] text-subtle">{gettext("Servers")}</legend>
          <input type="hidden" name="server_ids[]" value="" />
          <label :for={server <- @grant.servers} class="flex items-center gap-2.5 text-[0.8125rem]">
            <input
              type="checkbox"
              name="server_ids[]"
              value={server.id}
              checked={to_string(server.id) in @grant.server_ids}
              class="vip-check"
            />
            <span class="truncate">{server.name}</span>
            <span :if={@grant.failing[server.id]} class="text-[0.6875rem] vip-warn">
              {gettext("stays pending")}
            </span>
          </label>
        </fieldset>

        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">
            {gettext("Reason")} <span class="text-muted">{gettext("(kept in the history)")}</span>
          </span>
          <textarea
            name="reason"
            id="grant-reason"
            rows="2"
            maxlength="200"
            class="vip-field"
          >{@grant.reason}</textarea>
        </label>

        <label class="flex items-center gap-2.5 text-[0.8125rem] text-subtle">
          <input type="hidden" name="notify" value="false" />
          <input type="checkbox" name="notify" value="true" checked={@grant.notify} class="vip-check" />
          {gettext("Tell him in the game when he joins")}
        </label>

        <span class="flex-1"></span>
        <div class="rounded-[0.875rem] bg-secondary px-3.5 py-3 text-xs leading-normal text-subtle">
          <%= cond do %>
            <% @permanent -> %>
              {gettext("The VIP is permanent.")}
            <% @grant.stacking == "extend" -> %>
              {gettext("Repeat purchases are set to")}
              <strong class="font-semibold text-base-content">{gettext("extend")}</strong>: {gettext(
                "the VIP lasts until"
              )}
              <strong class="font-semibold text-base-content">
                <.vip_time id="grant-until" at={@until} format="date" />
              </strong>.
            <% true -> %>
              {gettext("Repeat purchases are set to")}
              <strong class="font-semibold text-base-content">{gettext("replace")}</strong>: {gettext(
                "the VIP lasts until"
              )}
              <strong class="font-semibold text-base-content">
                <.vip_time id="grant-until" at={@until} format="date" />
              </strong>.
          <% end %>
          {gettext("It goes in as an order of %{amount} made by %{admin}.",
            amount: money(0, VipShop.settings().currency),
            admin: @current_user.name || @current_user.username
          )}
        </div>
        <div class="flex gap-2.5">
          <.link patch={~p"/vip-shop/purchases"} class="vip-btn vip-btn-raised">
            {gettext("Cancel")}
          </.link>
          <button type="submit" id="grant-submit" class="vip-btn vip-btn-cta flex-1">
            {gettext("Grant VIP")}
          </button>
        </div>
      </form>
    </.vip_panel>
    """
  end

  defp initials(name) do
    name
    |> to_string()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
