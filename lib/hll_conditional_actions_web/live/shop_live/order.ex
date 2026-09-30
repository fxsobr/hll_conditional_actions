defmodule HllConditionalActionsWeb.ShopLive.Order do
  @moduledoc """
  Where the customer lands after paying: the order's progress - created,
  paid, delivered server by server, done - updating live as the payment is
  confirmed and each server takes the VIP, until when the VIP runs, and the
  receipt. Nobody has to refresh or wonder whether it worked.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Storefront
  alias HllConditionalActionsWeb.ShopFormat

  @tick_ms 5_000

  @impl Phoenix.LiveView
  def mount(%{"id" => id} = params, _session, socket) do
    customer = socket.assigns.current_customer

    case VipShop.get_order(id) do
      %{customer_id: owner} = order when owner == customer.id ->
        if connected?(socket) do
          VipShop.subscribe()
          Process.send_after(self(), :tick, @tick_ms)
        end

        settings = preview_settings(VipShop.settings(), params)

        {:ok,
         socket
         |> assign(:page_title, gettext("Order #%{id}", id: order.id))
         |> assign(:settings, settings)
         |> assign(:preferences, Storefront.preferences(customer))
         |> assign_order(order)}

      _other ->
        {:ok, push_navigate(socket, to: ~p"/shop/account")}
    end
  end

  defp assign_order(socket, order) do
    order = Repo.preload(order, [package: :servers], force: true)
    servers = order_servers(order)

    socket
    |> assign(:order, order)
    |> assign(:servers, servers)
    |> assign(:zone, ShopFormat.zone(servers))
    |> assign(:note, Storefront.order_note(order.id))
    |> assign(
      :next_try,
      if(order.status in ~w(paid partial failed), do: Storefront.next_delivery_try(order.id))
    )
    |> assign(:now, DateTime.utc_now())
  end

  # The package's servers; for a package deleted since, the ones in grants.
  defp order_servers(%{package: %{servers: [_ | _] = servers}}), do: servers

  defp order_servers(order) do
    order.grants
    |> Enum.filter(& &1.server_id)
    |> Enum.map(&%{id: &1.server_id, name: &1.server_name, game: :hll})
    |> Enum.uniq_by(& &1.id)
  end

  @impl Phoenix.LiveView
  def handle_info({:vip_order, %{id: id}}, %{assigns: %{order: %{id: id}}} = socket),
    do: {:noreply, assign_order(socket, VipShop.get_order(id))}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)

    socket =
      if socket.assigns.next_try,
        do: assign_order(socket, VipShop.get_order(socket.assigns.order.id)),
        else: assign(socket, :now, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("toggle-reminders", _params, socket) do
    current = socket.assigns.preferences.expiry_reminders

    {:ok, preferences} =
      Storefront.update_preferences(socket.assigns.current_customer, %{
        expiry_reminders: !current
      })

    {:noreply, assign(socket, :preferences, preferences)}
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    {granted, total} = Storefront.delivery_count(assigns.order)

    assigns =
      assigns
      |> assign(:granted, granted)
      |> assign(:total, total)
      |> assign(:phase, phase(assigns.order, granted, total, assigns.next_try))
      |> assign(:player, assigns.order.player_name || assigns.order.player_id)
      |> assign(:until, until(assigns.order))

    ~H"""
    <.shell
      current_path={@current_path}
      settings={@settings}
      current_customer={@current_customer}
      flash={@flash}
      footer={false}
    >
      <div class="flex flex-col gap-3 px-4 pb-8 sm:gap-5 sm:px-8 lg:px-12 lg:pb-7">
        <div class="flex min-h-11 flex-wrap items-center gap-3 sm:h-16 sm:gap-4">
          <.back_button href={~p"/shop/account"} label={gettext("Back to my orders")} />
          <h1 class="font-display text-[1.4375rem] font-semibold tracking-[-0.02em] sm:text-[1.875rem]">
            {gettext("Purchase")}
            <span class="font-mono text-[1.25rem] font-medium sm:text-[1.625rem]">#{@order.id}</span>
          </h1>
          <.status_pill id="order-status" phase={@phase} granted={@granted} total={@total} />
          <span class="grow"></span>
          <.stepper
            step={if @order.status in ~w(pending canceled), do: 2, else: 3}
            class="hidden lg:flex"
          />
        </div>

        <div class="grid grid-cols-[minmax(0,1fr)] gap-3 sm:gap-5 lg:grid-cols-[minmax(0,1fr)_27.5rem]">
          <section
            aria-labelledby="andamento"
            class="shop-panel flex min-h-0 flex-col overflow-hidden rounded-3xl sm:rounded-[1.75rem]"
          >
            <div class="shop-art relative h-[10.75rem] shrink-0">
              <img
                src={HllConditionalActionsWeb.Ui.server_art(List.first(@servers))}
                alt=""
                class="shop-art-img"
              />
              <div class="absolute inset-0 -z-10 bg-[linear-gradient(90deg,color-mix(in_oklab,var(--sh-panel)_95%,transparent)_0%,color-mix(in_oklab,var(--sh-panel)_75%,transparent)_50%,color-mix(in_oklab,var(--sh-panel)_25%,transparent)_100%)]">
              </div>
              <div class="relative flex h-full flex-col justify-end gap-1.5 px-5 py-6 sm:px-8 sm:py-7">
                <h2
                  id="andamento"
                  class="font-display text-2xl font-semibold tracking-[-0.02em] text-[var(--sh-text)] sm:text-[1.875rem]"
                >
                  {headline(@phase, @player, @granted, @total)}
                </h2>
                <span class="text-sm text-[var(--sh-text-2)] sm:text-[0.9375rem]">
                  {subline(@order, @current_customer)}
                </span>
              </div>
              <span
                :if={@phase in [:paying, :delivering]}
                class="shop-glass absolute top-5 right-6 flex h-7 items-center gap-1.5 rounded-full !border-0 px-3 text-xs font-semibold text-[var(--sh-accent-text)]"
              >
                <span class="shop-dot size-1.5 motion-safe:animate-pulse"></span>{gettext("Live")}
              </span>
            </div>

            <ol
              aria-label={gettext("Order progress")}
              class="flex grow flex-col px-5 py-6 sm:px-8 sm:py-7"
            >
              <.step
                state={:done}
                title={gettext("Order created")}
                text={created_text(@order)}
                time={ShopFormat.time_seconds(@order.inserted_at, @zone)}
              />
              <.step
                state={payment_state(@order)}
                title={payment_title(@order)}
                text={payment_text(@order)}
                time={@order.paid_at && ShopFormat.time_seconds(@order.paid_at, @zone)}
              />
              <.step
                :if={@order.status != "canceled"}
                state={delivery_state(@phase)}
                title={gettext("VIP delivered per server")}
                text={gettext("Each server confirms on its own. It usually takes seconds.")}
              >
                <div :if={@order.status != "pending"} class="mt-2.5 flex flex-col gap-2.5">
                  <.server_row
                    :for={server <- @servers}
                    server={server}
                    grant={Enum.find(@order.grants, &(&1.server_id == server.id))}
                    order={@order}
                    note={@note}
                    next_try={@next_try}
                    now={@now}
                    zone={@zone}
                  />
                </div>
              </.step>
              <.step
                :if={@order.status != "canceled"}
                state={if @phase == :done, do: :done, else: :todo}
                number={4}
                title={gettext("Ready")}
                text={done_text(@order, @phase, @total, @zone)}
                last
              />
            </ol>

            <div class="mx-5 mb-6 sm:mx-8 sm:mb-7">
              <.note icon="hero-shield-check">
                {gettext(
                  "If a server does not confirm, %{shop}'s team is warned and sorts it out for you. Nothing is charged again.",
                  shop: shop_name(@settings)
                )}
              </.note>
            </div>
          </section>

          <div class="flex min-h-0 flex-col gap-3 sm:gap-5">
            <section
              :if={@order.status != "canceled"}
              aria-labelledby="validade"
              class="shop-panel flex flex-col gap-3.5 rounded-3xl px-6 py-[1.375rem] sm:rounded-[1.75rem]"
            >
              <span id="validade" class="text-xs tracking-[0.06em] text-[var(--sh-text-3)] uppercase">
                {gettext("%{player}'s VIP is valid until", player: @player)}
              </span>
              <div class="flex items-baseline justify-between gap-3">
                <strong class="font-display text-[2.5rem] font-bold tracking-[-0.03em]">
                  {until_label(@until, @zone)}
                </strong>
                <span class="text-[0.8125rem] text-[var(--sh-text-2)]">
                  {duration(@order.duration_days)}
                </span>
              </div>
              <label
                :if={@current_customer.email && @order.duration_days && @settings.reminder_days > 0}
                class="shop-raised flex cursor-pointer items-center gap-3 rounded-2xl border border-[var(--sh-border-strong)] px-4 py-3.5"
              >
                <.icon name="hero-envelope" class="size-[18px] shrink-0 text-[var(--sh-accent)]" />
                <span class="flex grow flex-col gap-0.5">
                  <strong class="text-sm font-semibold">
                    {gettext("Get an email before it ends")}
                  </strong>
                  <span class="text-xs text-[var(--sh-text-3)]">
                    {ngettext(
                      "%{count} day before, at %{email}",
                      "%{count} days before, at %{email}",
                      @settings.reminder_days,
                      email: @current_customer.email
                    )}
                  </span>
                </span>
                <input
                  type="checkbox"
                  role="switch"
                  id="reminder-switch"
                  checked={@preferences.expiry_reminders}
                  phx-click="toggle-reminders"
                  class="peer sr-only"
                />
                <span class="shop-switch" aria-hidden="true"></span>
              </label>
            </section>

            <.receipt order={@order} settings={@settings} servers={@servers} zone={@zone} />
          </div>
        </div>
      </div>
    </.shell>
    """
  end

  attr :id, :string, required: true
  attr :phase, :atom, required: true
  attr :granted, :integer, required: true
  attr :total, :integer, required: true

  defp status_pill(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "shop-pill flex h-7 items-center gap-1.5 px-3 text-xs font-semibold",
        @phase in [:paying, :delivering, :stuck] && "shop-pill-warn",
        @phase == :done && "shop-pill-accent",
        @phase == :canceled && "shop-raised text-[var(--sh-text-2)]"
      ]}
    >
      <span class="shop-dot size-1.5"></span>
      <%= case @phase do %>
        <% :paying -> %>
          {gettext("Waiting for payment")}
        <% :delivering -> %>
          {gettext("Delivering · %{done} of %{total}", done: @granted, total: @total)}
        <% :stuck -> %>
          {gettext("Delivered on %{done} of %{total}", done: @granted, total: @total)}
        <% :done -> %>
          {gettext("Delivered")}
        <% :canceled -> %>
          {gettext("Canceled")}
      <% end %>
    </span>
    """
  end

  attr :state, :atom, required: true, doc: ":done, :current, :warn, :failed or :todo"
  attr :title, :string, required: true
  attr :text, :string, default: nil
  attr :time, :string, default: nil
  attr :number, :integer, default: nil
  attr :last, :boolean, default: false
  slot :inner_block

  defp step(assigns) do
    ~H"""
    <li class={[
      "relative grid grid-cols-[2.25rem_minmax(0,1fr)_auto] gap-x-4",
      !@last && "pb-[1.375rem]"
    ]}>
      <span
        :if={!@last}
        class={[
          "absolute top-9 bottom-0 left-[17px] w-0.5",
          if(@state == :done,
            do: "bg-[color-mix(in_oklab,var(--sh-accent)_35%,transparent)]",
            else: "bg-[var(--sh-border)]"
          )
        ]}
      ></span>
      <span class={[
        "flex size-9 items-center justify-center rounded-full",
        @state == :done && "shop-pill-accent",
        @state == :current && "border-2 border-[var(--sh-warn)] text-[var(--sh-warn)]",
        @state == :warn && "border-2 border-[var(--sh-warn)] text-[var(--sh-warn)]",
        @state == :failed && "border-2 border-[var(--sh-danger)] text-[var(--sh-danger)]",
        @state == :todo && "border border-[var(--sh-step)] text-[0.8125rem] text-[var(--sh-text-3)]"
      ]}>
        <.icon :if={@state == :done} name="hero-check" class="size-4" />
        <.icon
          :if={@state == :current}
          name="hero-arrow-path"
          class="size-4 motion-safe:animate-spin"
        />
        <.icon :if={@state == :warn} name="hero-exclamation-triangle" class="size-4" />
        <.icon :if={@state == :failed} name="hero-x-mark" class="size-4" />
        <span :if={@state == :todo}>{@number}</span>
      </span>
      <div class={["flex min-w-0 flex-col pt-[7px]", @inner_block != [] && "col-span-2"]}>
        <span class="flex flex-col gap-[3px]">
          <strong class={[
            "text-[0.9375rem] font-semibold",
            @state == :todo && "text-[var(--sh-text-2)]"
          ]}>
            {@title}
          </strong>
          <span :if={@text} class="text-[0.8125rem] text-[var(--sh-text-3)]">{@text}</span>
        </span>
        {render_slot(@inner_block)}
      </div>
      <span
        :if={@inner_block == []}
        class="pt-[9px] font-mono text-xs text-[var(--sh-text-3)]"
      >
        {@time}
      </span>
    </li>
    """
  end

  attr :server, :map, required: true
  attr :grant, :any, default: nil
  attr :order, :map, required: true
  attr :note, :any, default: nil
  attr :next_try, :any, default: nil
  attr :now, :any, required: true
  attr :zone, :string, required: true

  defp server_row(assigns) do
    status =
      case assigns.grant do
        %{status: "granted"} -> :granted
        %{status: "failed"} -> if(assigns.next_try, do: :retrying, else: :failed)
        _pending -> :pending
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <div
      id={"delivery-#{@server.id}"}
      class={[
        "flex items-center gap-3.5 rounded-[1.125rem] py-2.5 pr-4 pl-2.5",
        @status in [:retrying, :failed] &&
          "border border-[color-mix(in_oklab,var(--sh-warn)_25%,transparent)] bg-[color-mix(in_oklab,var(--sh-warn)_7%,transparent)]",
        @status not in [:retrying, :failed] && "shop-raised"
      ]}
    >
      <img
        src={HllConditionalActionsWeb.Ui.server_art(@server)}
        alt=""
        class="size-[3.25rem] shrink-0 rounded-[0.875rem] object-cover"
      />
      <span class="flex min-w-0 grow flex-col gap-0.5">
        <strong class="truncate text-sm font-semibold">{@server.name}</strong>
        <span class={[
          "text-xs",
          if(@status in [:retrying, :failed],
            do: "text-[var(--sh-text-2)]",
            else: "text-[var(--sh-text-3)]"
          )
        ]}>
          {row_text(@status, @grant, @order, @note, @server, @next_try, @now, @zone)}
        </span>
      </span>
      <span
        :if={@status == :granted and @grant}
        class="hidden font-mono text-xs text-[var(--sh-text-3)] sm:inline"
      >
        {ShopFormat.time_seconds(@grant.inserted_at, @zone)}
      </span>
      <span
        :if={@status == :retrying}
        class="hidden font-mono text-xs text-[var(--sh-text-3)] sm:inline"
      >
        {gettext("attempt %{n}", n: @next_try.attempt + 1)}
      </span>
      <span class={[
        "shop-pill flex h-7 shrink-0 items-center gap-1.5 px-3 text-xs font-semibold",
        @status == :granted && "shop-pill-accent",
        @status in [:pending, :retrying] && "shop-pill-warn",
        @status == :failed &&
          "bg-[color-mix(in_oklab,var(--sh-danger)_14%,transparent)] text-[var(--sh-danger)]"
      ]}>
        <%= case @status do %>
          <% :granted -> %>
            <.icon name="hero-check" class="size-3.5" />{gettext("Delivered")}
          <% :failed -> %>
            <.icon name="hero-x-mark" class="size-3.5" />{gettext("Failed")}
          <% _waiting -> %>
            <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />{gettext(
              "Delivering…"
            )}
        <% end %>
      </span>
    </div>
    """
  end

  defp row_text(:granted, grant, order, note, server, _next_try, _now, zone) do
    cond do
      note && note.delivered_server == server.name ->
        gettext("%{player} got the message in the game",
          player: order.player_name || order.player_id
        )

      grant.expires_at ->
        gettext("VIP until %{date}", date: ShopFormat.date(grant.expires_at, zone))

      true ->
        gettext("Permanent VIP")
    end
  end

  defp row_text(:retrying, _grant, _order, _note, _server, next_try, now, _zone) do
    seconds = max(DateTime.diff(next_try.at, now), 0)

    if seconds > 0,
      do: gettext("The server did not answer. Trying again in %{count} s.", count: seconds),
      else: gettext("The server did not answer. Trying again now.")
  end

  defp row_text(:failed, _grant, _order, _note, _server, _next_try, _now, _zone),
    do: gettext("The server refused the VIP. The team was warned.")

  defp row_text(:pending, _grant, _order, _note, _server, _next_try, _now, _zone),
    do: gettext("Waiting for the server to confirm.")

  attr :order, :map, required: true
  attr :settings, :map, required: true
  attr :servers, :list, required: true
  attr :zone, :string, required: true

  defp receipt(assigns) do
    assigns = assign(assigns, :rows, receipt_rows(assigns.order, assigns.servers, assigns.zone))

    ~H"""
    <section
      aria-labelledby="recibo"
      class="shop-panel flex grow flex-col gap-3.5 rounded-3xl px-6 py-[1.375rem] sm:rounded-[1.75rem]"
    >
      <div class="flex items-baseline">
        <h2 id="recibo" class="grow font-display text-xl font-semibold">{gettext("Receipt")}</h2>
        <span :if={Map.get(@order, :receipt_sent_at)} class="text-xs text-[var(--sh-text-3)]">
          {gettext("sent by email")}
        </span>
      </div>
      <dl class="grid grid-cols-[6.875rem_minmax(0,1fr)] gap-x-3 gap-y-2.5 text-sm">
        <%= for {label, value, mono} <- @rows do %>
          <dt class="text-[0.8125rem] text-[var(--sh-text-3)]">{label}</dt>
          <dd class={["break-words", mono && "font-mono text-[0.8125rem]"]}>{value}</dd>
        <% end %>
      </dl>
      <div class="shop-divider"></div>
      <div class="flex justify-between text-sm text-[var(--sh-text-2)]">
        <span>{gettext("Subtotal")}</span>
        <span>{VipShop.format_money(@order.amount_cents + @order.discount_cents, @order.currency)}</span>
      </div>
      <div :if={@order.coupon_code} class="flex justify-between text-sm">
        <span class="flex items-center gap-2 text-[var(--sh-text-2)]">
          {gettext("Coupon")}
          <span class="rounded-md bg-[var(--sh-border)] px-[7px] py-0.5 font-mono text-[0.6875rem] text-[var(--sh-text)]">
            {@order.coupon_code}
          </span>
        </span>
        <span class="text-[var(--sh-accent-text)]">
          − {VipShop.format_money(@order.discount_cents, @order.currency)}
        </span>
      </div>
      <div class="flex items-baseline justify-between">
        <span class="text-[0.9375rem] font-semibold">
          {if @order.status in ~w(pending canceled), do: gettext("Total"), else: gettext("Total paid")}
        </span>
        <span class="font-display text-[1.75rem] font-bold">
          {VipShop.format_money(@order.amount_cents, @order.currency)}
        </span>
      </div>
      <span class="grow"></span>
      <div class="grid grid-cols-2 gap-2.5">
        <button
          type="button"
          id="download-receipt"
          phx-hook=".ReceiptDownload"
          data-filename={"#{gettext("receipt")}-#{@order.id}.txt"}
          data-receipt={receipt_text(@order, @rows, @settings)}
          class="shop-btn shop-btn-secondary h-12 gap-2 text-sm !font-medium"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" />{gettext("Download receipt")}
        </button>
        <.link navigate={~p"/shop/account"} class="shop-btn shop-btn-accent h-12 text-sm">
          {gettext("See my orders")}
        </.link>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReceiptDownload">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const blob = new Blob([this.el.dataset.receipt], {type: "text/plain;charset=utf-8"})
              const link = document.createElement("a")
              link.href = URL.createObjectURL(blob)
              link.download = this.el.dataset.filename
              document.body.appendChild(link)
              link.click()
              link.remove()
              setTimeout(() => URL.revokeObjectURL(link.href), 1000)
            })
          }
        }
      </script>
    </section>
    """
  end

  defp receipt_rows(order, servers, zone) do
    [
      {gettext("Purchase"), "##{order.id}", true},
      {gettext("Date"), ShopFormat.full(order.inserted_at, zone), false},
      {gettext("Package"), Enum.join([order.package_name, duration(order.duration_days)], " · "),
       false},
      {gettext("For"), receipt_player(order), false},
      {gettext("Servers"), ShopFormat.join(Enum.map(servers, &short_name/1)), false},
      {gettext("Payment"), Labels.payment_provider(order.provider || ""), false},
      order.provider_ref && {gettext("Transaction"), order.provider_ref, true}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp receipt_player(order) do
    name = order.player_name || order.player_id
    if name == order.player_id, do: name, else: "#{name} · #{order.player_id}"
  end

  defp receipt_text(order, rows, settings) do
    lines = for {label, value, _mono} <- rows, do: "#{label}: #{value}"

    money = fn cents -> VipShop.format_money(cents, order.currency) end

    totals =
      [
        "#{gettext("Subtotal")}: #{money.(order.amount_cents + order.discount_cents)}",
        order.coupon_code &&
          "#{gettext("Coupon")} #{order.coupon_code}: -#{money.(order.discount_cents)}",
        "#{gettext("Total")}: #{money.(order.amount_cents)}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([shop_name(settings), gettext("Receipt"), "" | lines] ++ ["" | totals], "\n")
  end

  # ── Phases and texts ───────────────────────────────────────────────────────

  defp phase(%{status: "pending"}, _granted, _total, _next), do: :paying
  defp phase(%{status: "canceled"}, _granted, _total, _next), do: :canceled
  defp phase(%{status: "fulfilled"}, _granted, _total, _next), do: :done
  defp phase(%{status: "paid"}, _granted, _total, _next), do: :delivering
  defp phase(_order, _granted, _total, next) when not is_nil(next), do: :delivering
  defp phase(_order, _granted, _total, _next), do: :stuck

  defp headline(:paying, _player, _granted, _total), do: gettext("Waiting for the payment.")

  defp headline(:delivering, player, _granted, _total),
    do: gettext("Paid. %{player}'s VIP is on its way.", player: player)

  defp headline(:done, player, _granted, _total),
    do: gettext("Done. %{player}'s VIP is active.", player: player)

  defp headline(:stuck, player, granted, total),
    do:
      gettext("%{player}'s VIP reached %{done} of %{total} servers.",
        player: player,
        done: granted,
        total: total
      )

  defp headline(:canceled, _player, _granted, _total),
    do: gettext("The payment did not go through.")

  defp subline(order, customer) do
    [
      order.package_name,
      order.gift && gift_from(customer),
      order.status in ~w(pending paid partial failed) && gettext("this page updates by itself")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp gift_from(customer), do: gettext("a gift from %{name}", name: customer_name(customer))

  defp created_text(order) do
    [
      gettext("%{package} for %{player}",
        package: order.package_name,
        player: order.player_name || order.player_id
      ),
      order.coupon_code && gettext("coupon %{code}", code: order.coupon_code)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp payment_state(%{status: "pending"}), do: :current
  defp payment_state(%{status: "canceled"}), do: :failed
  defp payment_state(_order), do: :done

  defp payment_title(%{status: "pending"}), do: gettext("Waiting for the payment")
  defp payment_title(%{status: "canceled"}), do: gettext("Payment not approved")
  defp payment_title(_order), do: gettext("Payment approved")

  defp payment_text(%{status: "pending"} = order),
    do:
      gettext("%{provider} confirms it on its own. It usually takes seconds.",
        provider: Labels.payment_provider(order.provider || "")
      )

  defp payment_text(%{status: "canceled"}),
    do: gettext("Nothing was charged. You can try again with another method.")

  defp payment_text(order) do
    gettext("%{provider} · %{amount}",
      provider: Labels.payment_provider(order.provider || ""),
      amount: VipShop.format_money(order.amount_cents, order.currency)
    )
  end

  defp delivery_state(:done), do: :done
  defp delivery_state(:delivering), do: :current
  defp delivery_state(:stuck), do: :warn
  defp delivery_state(_phase), do: :todo

  defp done_text(order, :done, _total, zone) do
    gettext("VIP active since %{time}.",
      time: ShopFormat.time(order.fulfilled_at || order.updated_at, zone)
    )
  end

  defp done_text(order, _phase, total, _zone) do
    if order.customer && order.customer.email,
      do:
        ngettext(
          "We send an email when the server confirms.",
          "We send an email when the %{count} servers confirm.",
          total
        ),
      else: gettext("This page shows it as soon as every server confirms.")
  end

  # When the VIP ends: the latest expiry the servers took, or - before any
  # took it - the package's days from now.
  defp until(order) do
    granted = Enum.filter(order.grants, &(&1.status == "granted"))

    cond do
      is_nil(order.duration_days) -> :permanent
      granted == [] -> DateTime.add(DateTime.utc_now(), order.duration_days * 86_400, :second)
      Enum.any?(granted, &is_nil(&1.expires_at)) -> :permanent
      true -> granted |> Enum.map(& &1.expires_at) |> Enum.max(DateTime)
    end
  end

  defp until_label(:permanent, _zone), do: gettext("Permanent")
  defp until_label(at, zone), do: ShopFormat.date(at, zone)
end
