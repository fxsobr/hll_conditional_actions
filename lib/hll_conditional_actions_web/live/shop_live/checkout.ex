defmodule HllConditionalActionsWeb.ShopLive.Checkout do
  @moduledoc """
  Buying a package - "Finalizar compra": who gets the VIP (one of the
  customer's players, or any player found by name as a gift, with an
  optional message shown to them in the game), a coupon, and how to pay.
  The summary shows until when the VIP will run for that player. Paying
  opens the provider's page; the customer comes back to the order's live
  page.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Storefront
  alias HllConditionalActions.VipShop.Storefront.OrderNote
  alias HllConditionalActionsWeb.Endpoint
  alias HllConditionalActionsWeb.ShopFormat

  @impl Phoenix.LiveView
  def mount(%{"id" => id} = params, _session, socket) do
    case Enum.find(VipShop.list_active_packages(), &(to_string(&1.id) == id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That package is not on sale."))
         |> push_navigate(to: ~p"/shop")}

      package ->
        customer = socket.assigns.current_customer
        players = VipShop.list_customer_players(customer)
        providers = VipShop.enabled_providers()

        {:ok,
         socket
         |> assign(:page_title, gettext("Checkout"))
         |> assign(:settings, preview_settings(VipShop.settings(), params))
         |> assign(:package, package)
         |> assign(:zone, ShopFormat.zone(package.servers))
         |> assign(:players, players)
         |> assign(:providers, providers)
         |> assign(:gift?, players == [])
         |> assign(:player, players |> List.first() |> then(&(&1 && to_string(&1.id))))
         |> assign(:gift, nil)
         |> assign(:provider, providers |> List.first() |> then(&(&1 && &1.provider)))
         |> assign(:search, "")
         |> assign(:results, [])
         |> assign(:search_error, false)
         |> assign(:message, "")
         |> assign(:coupon, nil)
         |> assign(:coupon_code, "")
         |> assign(:discount, 0)
         |> assign(:coupon_error, nil)
         |> assign(:picking, false)
         |> assign(:error, nil)
         |> assign_vips(Enum.map(players, & &1.player_id))}
    end
  end

  defp assign_vips(socket, player_ids) do
    known = Map.get(socket.assigns, :vips, %{})
    assign(socket, :vips, Map.merge(known, Storefront.vip_until(player_ids)))
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("change", %{"_target" => ["q"]} = params, socket) do
    term = params["q"] || ""

    {results, error?} =
      case Storefront.search_players(term) do
        {:ok, results} -> {Enum.take(results, 6), false}
        {:error, _reason} -> {[], true}
      end

    {:noreply,
     socket
     |> assign(search: term, results: results, search_error: error?)
     |> assign_vips(Enum.map(results, & &1.player_id))}
  end

  def handle_event("change", params, socket) do
    socket =
      socket
      |> assign(:provider, params["provider"] || socket.assigns.provider)
      |> assign(
        :message,
        String.slice(params["message"] || socket.assigns.message, 0, OrderNote.max_length())
      )
      |> assign(:error, nil)
      |> apply_change(params)

    {:noreply, socket}
  end

  def handle_event("toggle-gift", _params, socket) do
    {:noreply, assign(socket, :gift?, !socket.assigns.gift?)}
  end

  def handle_event("pick", _params, socket) do
    {:noreply, assign(socket, :picking, !socket.assigns.picking)}
  end

  def handle_event("coupon", %{"code" => code}, socket) do
    case Storefront.apply_coupon(code, socket.assigns.package) do
      {:ok, nil, _discount} ->
        {:noreply, assign(socket, coupon: nil, coupon_code: "", discount: 0, coupon_error: nil)}

      {:ok, coupon, discount} ->
        {:noreply,
         assign(socket,
           coupon: coupon,
           coupon_code: coupon.code,
           discount: discount,
           coupon_error: nil
         )}

      {:error, :invalid_coupon} ->
        {:noreply,
         assign(socket,
           coupon: nil,
           coupon_code: code,
           discount: 0,
           coupon_error: gettext("This coupon is not valid.")
         )}
    end
  end

  def handle_event("remove-coupon", _params, socket) do
    {:noreply, assign(socket, coupon: nil, coupon_code: "", discount: 0, coupon_error: nil)}
  end

  def handle_event("pay", params, socket) do
    socket =
      socket
      |> assign(:provider, params["provider"] || socket.assigns.provider)
      |> assign(:message, params["message"] || socket.assigns.message)
      |> then(fn socket ->
        if params["player"] && !socket.assigns.gift?,
          do: assign(socket, :player, params["player"]),
          else: socket
      end)

    %{current_customer: customer, package: package, provider: provider} = socket.assigns

    with {:ok, player} <- recipient(socket.assigns),
         {:ok, order} <-
           VipShop.create_order(customer, package, player, provider,
             coupon: socket.assigns.coupon && socket.assigns.coupon.code
           ),
         {:ok, _note} <- Storefront.put_order_note(order, socket.assigns.message),
         {:ok, url} <- VipShop.start_checkout(order, urls(provider, customer, order)) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, reason} when is_binary(reason) ->
        {:noreply, assign(socket, :error, reason)}

      {:error, :invalid_coupon} ->
        {:noreply, assign(socket, :error, gettext("This coupon is not valid."))}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :error, gettext("The payment could not be started. Please try again."))}
    end
  end

  defp apply_change(socket, params) do
    cond do
      params["_target"] == ["gift_on"] ->
        assign(socket, :gift?, params["gift_on"] == "true")

      params["_target"] == ["gift"] and params["gift"] ->
        pick_gift(socket, params["gift"])

      params["_target"] == ["player"] and params["player"] ->
        assign(socket, gift?: false, player: params["player"], picking: false)

      # A plain submit of the form (as in tests) picks the player it names.
      params["player"] && !params["_target"] ->
        assign(socket, gift?: false, player: params["player"])

      true ->
        socket
    end
  end

  defp pick_gift(socket, player_id) do
    case Enum.find(socket.assigns.results, &(&1.player_id == player_id)) do
      nil ->
        socket

      result ->
        assign(socket,
          gift?: true,
          picking: false,
          gift: %{
            player_id: result.player_id,
            player_name: result.name,
            gift: true,
            found: result
          }
        )
    end
  end

  defp recipient(%{gift?: true, gift: %{} = gift}),
    do: {:ok, Map.take(gift, [:player_id, :player_name, :gift])}

  defp recipient(%{gift?: true}), do: {:error, gettext("Pick the player who gets the gift.")}

  defp recipient(%{players: players, player: id}) do
    case Enum.find(players, &(to_string(&1.id) == id)) do
      nil -> {:error, gettext("Pick one of your players.")}
      player -> {:ok, player}
    end
  end

  defp urls(provider, customer, order) do
    %{
      success: Endpoint.url() <> ~p"/shop/return/#{provider}?order=#{order.id}",
      cancel: Endpoint.url() <> ~p"/shop/orders/#{order.id}",
      webhook: Endpoint.url() <> ~p"/webhooks/#{provider}",
      email: customer.email
    }
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:total, assigns.package.price_cents - assigns.discount)
      |> assign(:who, who(assigns))
      |> assign(:provider_row, Enum.find(assigns.providers, &(&1.provider == assigns.provider)))

    assigns =
      assign(
        assigns,
        :until,
        Storefront.valid_until(
          assigns.package,
          assigns.who && Map.get(assigns.vips, assigns.who.player_id),
          assigns.settings.stacking
        )
      )

    ~H"""
    <.shell
      current_path={@current_path}
      settings={@settings}
      current_customer={@current_customer}
      flash={@flash}
      footer={false}
      menu={false}
    >
      <div class="flex flex-col gap-3 px-4 pb-44 sm:gap-5 sm:px-8 lg:px-12 lg:pb-7">
        <div class="flex min-h-11 items-center gap-3 sm:h-16 sm:gap-5">
          <.back_button href={~p"/shop#pacotes"} label={gettext("Back to the packages")} />
          <div class="flex flex-col gap-px">
            <span class="text-xs text-[var(--sh-text-3)] lg:hidden">
              {gettext("Step 2 of 3")} ·
              <span class="font-semibold text-[var(--sh-accent-text)]">{gettext("Payment")}</span>
            </span>
            <h1 class="font-display text-[1.4375rem] font-semibold tracking-[-0.02em] sm:text-[1.875rem]">
              {gettext("Checkout")}
            </h1>
          </div>
          <span class="grow"></span>
          <.stepper step={2} class="hidden lg:flex" />
        </div>

        <p :if={@providers == []} class="shop-panel rounded-[1.75rem] p-6 text-[var(--sh-text-2)]">
          {gettext("Payments are not available right now.")}
        </p>

        <div
          :if={@providers != []}
          class="flex flex-col gap-3 lg:grid lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] lg:items-start lg:gap-5 xl:grid-cols-[30rem_minmax(0,1fr)_26.25rem]"
        >
          <form
            id="checkout-form"
            phx-change="change"
            phx-submit="pay"
            class="contents"
            autocomplete="off"
          >
            <.recipient_section {assigns} />
            <.payment_section {assigns} />
            <.summary {assigns} />
          </form>
          <.coupon_section {assigns} />
        </div>
      </div>
    </.shell>
    """
  end

  # The player the order is for, as the summary shows them.
  defp who(%{gift?: true, gift: %{} = gift}),
    do: %{
      player_id: gift.player_id,
      name: gift.player_name,
      gift?: true,
      online?: gift.found.online?
    }

  defp who(%{gift?: true}), do: nil

  defp who(%{players: players, player: id}) do
    case Enum.find(players, &(to_string(&1.id) == id)) do
      nil ->
        nil

      p ->
        %{
          player_id: p.player_id,
          name: p.player_name || p.player_id,
          gift?: false,
          online?: false
        }
    end
  end

  defp recipient_section(assigns) do
    ~H"""
    <section
      id="checkout-recipient"
      aria-labelledby="quem-recebe"
      class={[
        "shop-panel order-2 flex-col gap-3.5 rounded-3xl p-4 sm:rounded-[1.75rem] sm:p-6 lg:order-none lg:row-span-2 lg:flex xl:col-start-1 xl:row-start-1",
        "flex"
      ]}
    >
      <div class={[
        "flex-col gap-3.5",
        if(@picking or is_nil(@who), do: "flex", else: "hidden lg:flex")
      ]}>
        <div class="flex flex-col gap-1">
          <h2 id="quem-recebe" class="font-display text-[1.3125rem] font-semibold">
            {gettext("Who gets the VIP")}
          </h2>
          <span class="text-[0.8125rem] text-[var(--sh-text-3)]">
            {ngettext(
              "The VIP is applied to this player, on the server.",
              "The VIP is applied to this player, on the %{count} servers.",
              length(@package.servers)
            )}
          </span>
        </div>

        <span
          :if={@players != []}
          class="mt-1 text-xs tracking-[0.06em] text-[var(--sh-text-3)] uppercase"
        >
          {gettext("Your players")}
        </span>
        <label
          :for={player <- @players}
          class={[
            "shop-choice flex items-center gap-3 px-3.5 py-3",
            (!@gift? and to_string(player.id) == @player) && "is-on"
          ]}
        >
          <input
            type="radio"
            name="player"
            value={player.id}
            checked={!@gift? and to_string(player.id) == @player}
            class="shop-radio"
          />
          <.initials_tile
            name={player.player_name || player.player_id}
            class="size-[2.375rem] text-xs"
          />
          <span class="flex min-w-0 grow flex-col gap-0.5">
            <strong class="truncate text-sm font-semibold">{player.player_name || player.player_id}</strong>
            <span class="truncate font-mono text-[0.6875rem] text-[var(--sh-text-3)]">
              {player.player_id}
            </span>
          </span>
          <span class="text-right text-xs text-[var(--sh-text-2)]">
            {vip_note(Map.get(@vips, player.player_id), @zone)}
          </span>
        </label>
        <p :if={@players == []} class="text-[0.8125rem] text-[var(--sh-text-2)]">
          {gettext("No player linked to your account yet.")}
          <.link navigate={~p"/shop/account"} class="shop-link">{gettext("Link my player")}</.link>
        </p>

        <label class="shop-raised flex cursor-pointer items-center gap-3 rounded-2xl border border-[var(--sh-border-strong)] px-4 py-3.5">
          <.icon name="hero-gift" class="size-5 shrink-0 text-[var(--sh-accent)]" />
          <span class="flex grow flex-col gap-0.5">
            <strong class="text-sm font-semibold">{gettext("Is it for someone else? Give as a gift")}</strong>
            <span class="text-xs text-[var(--sh-text-3)]">{gettext(
              "Search for the player who gets it"
            )}</span>
          </span>
          <input type="hidden" name="gift_on" value="false" />
          <input
            type="checkbox"
            name="gift_on"
            value="true"
            role="switch"
            checked={@gift?}
            class="peer sr-only"
            id="gift-switch"
          />
          <span class="shop-switch" aria-hidden="true"></span>
        </label>

        <div :if={@gift?} id="gift-picker" class="flex flex-col gap-3.5">
          <label class="flex flex-col gap-2">
            <span class="text-[0.8125rem] font-medium text-[var(--sh-text-2)]">
              {gettext("Name as it shows in the game")}
            </span>
            <span class="shop-field h-12 px-4">
              <.icon name="hero-magnifying-glass" class="size-[18px] shrink-0" />
              <input
                type="search"
                name="q"
                value={@search}
                phx-debounce="400"
                placeholder={gettext("Player name")}
                class="h-full text-[0.9375rem]"
              />
            </span>
          </label>
          <span :if={@search_error} class="text-xs text-[var(--sh-danger)]">
            {gettext("The player list is unavailable right now. Try again in a moment.")}
          </span>
          <span :if={@results != []} class="text-xs text-[var(--sh-text-3)]">
            {ngettext(
              "%{count} player in the history of %{shop}'s servers",
              "%{count} players in the history of %{shop}'s servers",
              length(@results),
              shop: shop_name(@settings)
            )}
          </span>
          <span
            :if={@results == [] and String.length(String.trim(@search)) >= 2 and !@search_error}
            class="text-xs text-[var(--sh-text-3)]"
          >
            {gettext("Nobody with that name played on the servers.")}
          </span>
          <div
            :if={@results != [] or @gift}
            role="radiogroup"
            aria-label={gettext("Search results")}
            class="flex flex-col gap-1.5"
          >
            <.result_row
              :for={result <- results_with_pick(@results, @gift)}
              result={result}
              picked={@gift && @gift.player_id == result.player_id}
              zone={@zone}
            />
          </div>
        </div>
      </div>

      <%!-- Phone, once someone is picked: the message only. --%>
      <label class="mt-0.5 flex flex-col gap-2">
        <span class="flex justify-between text-[0.8125rem] font-medium text-[var(--sh-text-2)]">
          {gettext("Message in the game")}
          <span class="font-normal text-[var(--sh-text-3)]">
            {gettext("optional")} · {String.length(@message)}/{OrderNote.max_length()}
          </span>
        </span>
        <span class="shop-field h-12 px-4">
          <input
            type="text"
            name="message"
            value={@message}
            maxlength={OrderNote.max_length()}
            phx-debounce="300"
            placeholder={gettext("Shown to the player when the VIP arrives")}
            class="h-full text-sm"
          />
        </span>
      </label>
    </section>
    """
  end

  attr :result, :map, required: true
  attr :picked, :boolean, default: false
  attr :zone, :string, required: true

  defp result_row(assigns) do
    ~H"""
    <label class={[
      "shop-choice flex items-center gap-3 border-transparent px-3.5 py-2.5",
      @picked && "is-on"
    ]}>
      <input type="radio" name="gift" value={@result.player_id} checked={@picked} class="shop-radio" />
      <.initials_tile
        name={@result.name}
        class="size-9 text-xs"
        tone={if @picked, do: "person", else: "muted"}
      />
      <span class="flex min-w-0 grow flex-col gap-0.5">
        <strong class="truncate text-sm font-semibold">{@result.name}</strong>
        <span class="truncate font-mono text-[0.6875rem] text-[var(--sh-text-3)]">{@result.player_id}</span>
      </span>
      <span class="flex shrink-0 flex-col items-end gap-0.5">
        <span
          :if={@result.online?}
          class="flex items-center gap-1.5 text-xs text-[var(--sh-accent-text)]"
        >
          <span class="shop-dot size-1.5"></span>{gettext("online now")}
        </span>
        <span :if={!@result.online? and @result.last_seen} class="text-xs text-[var(--sh-text-2)]">
          {gettext("seen %{when}", when: ShopFormat.seen(@result.last_seen, @zone))}
        </span>
      </span>
    </label>
    """
  end

  # The picked gift stays listed after a new search.
  defp results_with_pick(results, nil), do: results

  defp results_with_pick(results, gift) do
    if Enum.any?(results, &(&1.player_id == gift.player_id)),
      do: results,
      else: [gift.found | results]
  end

  defp payment_section(assigns) do
    ~H"""
    <section
      id="checkout-payment"
      aria-labelledby="pagamento"
      class="shop-panel order-4 flex flex-col gap-3.5 rounded-3xl p-4 sm:rounded-[1.75rem] sm:px-6 sm:py-[1.375rem] lg:order-none xl:col-start-2 xl:row-start-2"
    >
      <h2 id="pagamento" class="font-display text-lg font-semibold sm:text-xl">
        {gettext("Payment")}
      </h2>
      <div role="radiogroup" aria-label={gettext("How to pay")} class="grid grid-cols-2 gap-2">
        <label
          :for={p <- @providers}
          class={[
            "shop-choice flex min-h-[3.75rem] flex-col justify-center gap-1.5 px-3.5 py-2.5 sm:p-3.5",
            p.provider == @provider && "is-on"
          ]}
        >
          <span class="flex items-center justify-between gap-2">
            <strong class="text-[0.9375rem] font-semibold">{provider_title(p.provider)}</strong>
            <input
              type="radio"
              name="provider"
              value={p.provider}
              checked={p.provider == @provider}
              class="shop-radio"
            />
          </span>
          <span class="text-xs text-[var(--sh-text-3)]">
            {gettext("via %{provider}", provider: Labels.payment_provider(p.provider))}
          </span>
        </label>
      </div>

      <div
        :if={@provider_row}
        class="hidden min-h-[15rem] grow flex-col items-center justify-center gap-3.5 rounded-[1.25rem] border border-dashed border-[var(--sh-step)] bg-[var(--sh-well)] p-5 text-center sm:flex"
      >
        <span class="shop-raised flex size-[7.5rem] items-center justify-center rounded-2xl border border-[var(--sh-border-strong)] text-[var(--sh-text-3)]">
          <.icon name="hero-arrow-top-right-on-square" class="size-12" />
        </span>
        <strong class="text-sm font-semibold">
          {gettext("%{provider}'s payment page", provider: Labels.payment_provider(@provider))}
        </strong>
        <span class="max-w-[18rem] text-[0.8125rem] leading-normal text-[var(--sh-text-3)]">
          {gettext(
            "It opens when you tap pay. You pay there with %{methods} and come back here to follow the order.",
            methods: methods_text(Storefront.methods(@provider))
          )}
        </span>
      </div>

      <ol
        :if={@provider_row}
        class="hidden flex-col gap-2 text-[0.8125rem] text-[var(--sh-text-2)] sm:flex"
      >
        <li class="flex gap-2.5">
          <span class="font-mono text-[var(--sh-text-3)]">1</span>{gettext(
            "Tap pay and open %{provider}'s page",
            provider: Labels.payment_provider(@provider)
          )}
        </li>
        <li class="flex gap-2.5">
          <span class="font-mono text-[var(--sh-text-3)]">2</span>{gettext("Pay with %{methods}",
            methods: methods_text(Storefront.methods(@provider))
          )}
        </li>
        <li class="flex gap-2.5">
          <span class="font-mono text-[var(--sh-text-3)]">3</span>{gettext(
            "Done: the delivery starts on its own"
          )}
        </li>
      </ol>

      <div class="flex items-start gap-2.5 text-xs leading-normal text-[var(--sh-text-2)] sm:hidden">
        <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
        <span>{lock_text(@provider, @settings)}</span>
      </div>
    </section>
    """
  end

  defp coupon_section(assigns) do
    ~H"""
    <section
      id="checkout-coupon"
      aria-labelledby="cupom"
      class="shop-panel order-3 flex flex-col gap-3 rounded-3xl p-4 sm:rounded-[1.75rem] sm:px-6 sm:py-[1.375rem] lg:order-none xl:col-start-2 xl:row-start-1"
    >
      <h2 id="cupom" class="font-display text-lg font-semibold sm:text-xl">{gettext("Coupon")}</h2>
      <form id="coupon-form" phx-submit="coupon" class="flex gap-2">
        <label class={[
          "shop-field h-12 min-w-0 grow px-3.5",
          @coupon && "is-ok",
          @coupon_error && "is-error"
        ]}>
          <span class="sr-only">{gettext("Coupon code")}</span>
          <input
            type="text"
            name="code"
            value={@coupon_code}
            placeholder={gettext("Coupon code")}
            readonly={@coupon != nil}
            class="h-full font-mono text-sm uppercase placeholder:font-sans placeholder:normal-case"
          />
          <.icon :if={@coupon} name="hero-check" class="size-[18px] shrink-0 text-[var(--sh-accent)]" />
        </label>
        <button
          :if={!@coupon}
          type="submit"
          class="shop-btn shop-btn-secondary h-12 px-4 text-[0.8125rem] !font-normal"
        >
          {gettext("Apply")}
        </button>
        <button
          :if={@coupon}
          type="button"
          phx-click="remove-coupon"
          class="shop-btn shop-btn-secondary h-12 px-4 text-[0.8125rem] !font-normal"
        >
          {gettext("Remove")}
        </button>
      </form>
      <span
        :if={@coupon}
        id="coupon-applied"
        class="text-xs text-[var(--sh-accent-text)] sm:text-[0.8125rem]"
      >
        {coupon_line(@coupon, @discount, @package, @zone)}
      </span>
      <span :if={@coupon_error} class="text-[0.8125rem] text-[var(--sh-danger)]">{@coupon_error}</span>
    </section>
    """
  end

  defp summary(assigns) do
    assigns =
      assign(
        assigns,
        :art,
        HllConditionalActionsWeb.Ui.server_art(List.first(assigns.package.servers))
      )

    ~H"""
    <aside
      id="checkout-summary"
      aria-labelledby="resumo"
      class="shop-panel order-1 flex flex-col overflow-hidden rounded-3xl sm:rounded-[1.75rem] lg:order-none lg:col-start-2 lg:row-span-2 lg:row-start-1 xl:col-start-3"
    >
      <div class="shop-art relative h-24 shrink-0 sm:h-[8.75rem]">
        <img src={@art} alt="" class="shop-art-img" />
        <div class="absolute inset-0 -z-10 bg-[linear-gradient(180deg,color-mix(in_oklab,var(--sh-panel)_20%,transparent)_0%,color-mix(in_oklab,var(--sh-panel)_95%,transparent)_100%)]">
        </div>
        <div class="absolute inset-x-4 bottom-3 flex items-end justify-between gap-3 sm:inset-x-6 sm:bottom-4">
          <span class="flex min-w-0 flex-col gap-0.5">
            <span
              id="resumo"
              class="text-[0.6875rem] tracking-[0.06em] text-[var(--sh-img-text-2)] uppercase sm:text-xs"
            >
              {gettext("Order summary")}
            </span>
            <strong class="truncate font-display text-xl font-semibold sm:text-2xl">{@package.name}</strong>
            <span class="text-xs text-[var(--sh-img-text-2)] sm:hidden">
              {summary_line(@package, @until, @zone)}
            </span>
          </span>
          <span class="shop-pill hidden shrink-0 bg-[var(--sh-accent)] px-2.5 py-[5px] text-xs font-bold text-[var(--sh-on-accent)] sm:inline-flex">
            {duration(@package.duration_days)}
          </span>
        </div>
      </div>

      <%!-- Phone: who gets it, with a way to change. --%>
      <div class="flex items-center gap-3 py-2.5 pr-2 pl-4 sm:hidden">
        <.initials_tile name={(@who && @who.name) || "?"} class="size-9 text-xs" />
        <span class="flex min-w-0 grow flex-col gap-px">
          <strong class="truncate text-sm font-semibold">
            {if @who,
              do: gettext("For %{name}", name: @who.name),
              else: gettext("Pick who gets the VIP")}
          </strong>
          <span :if={@who} class="truncate text-xs text-[var(--sh-text-3)]">
            {recipient_note(@who, @players, @current_customer)}
            <span :if={@who.online?} class="text-[var(--sh-accent-text)]">· {gettext("online now")}</span>
          </span>
        </span>
        <button
          type="button"
          phx-click="pick"
          class="shop-link flex h-11 items-center px-3 text-sm !font-medium"
        >
          {if @who, do: gettext("Change"), else: gettext("Pick")}
        </button>
      </div>

      <div class="hidden flex-col gap-3.5 px-6 pt-5 pb-6 sm:flex">
        <div class="grid grid-cols-[5.75rem_minmax(0,1fr)] items-start gap-3 text-sm">
          <span class="text-[0.8125rem] text-[var(--sh-text-3)]">{gettext("For")}</span>
          <span class="flex flex-col gap-0.5">
            <strong class="font-semibold">{(@who && @who.name) || "—"}</strong>
            <span :if={@who} class="text-xs text-[var(--sh-text-2)]">
              {recipient_note(@who, @players, @current_customer)}
            </span>
          </span>
          <span class="text-[0.8125rem] text-[var(--sh-text-3)]">{gettext("Servers")}</span>
          <span class="flex flex-wrap gap-1.5">
            <span
              :for={server <- @package.servers}
              class="shop-raised shop-pill px-[9px] py-1 text-xs font-semibold"
            >
              {server.name}
            </span>
          </span>
          <span class="text-[0.8125rem] text-[var(--sh-text-3)]">{gettext("Valid")}</span>
          <span>
            {until_label(@until, @zone)}
            <span :if={@who} class="block text-xs text-[var(--sh-text-3)]">
              {current_vip_note(@who, Map.get(@vips, @who.player_id), @zone)}
            </span>
          </span>
        </div>
        <div class="shop-divider"></div>
        <div class="flex justify-between text-sm text-[var(--sh-text-2)]">
          <span>{gettext("Subtotal")}</span><span>{VipShop.format_money(
            @package.price_cents,
            @package.currency
          )}</span>
        </div>
        <div :if={@coupon} class="flex justify-between text-sm">
          <span class="flex items-center gap-2 text-[var(--sh-text-2)]">
            {gettext("Coupon")}
            <span class="rounded-md bg-[var(--sh-border)] px-[7px] py-0.5 font-mono text-[0.6875rem] text-[var(--sh-text)]">
              {@coupon.code}
            </span>
          </span>
          <span class="text-[var(--sh-accent-text)]">− {VipShop.format_money(
            @discount,
            @package.currency
          )}</span>
        </div>
        <div class="shop-divider"></div>
        <div class="flex items-baseline justify-between">
          <span class="text-[0.9375rem] font-semibold">{gettext("Total")}</span>
          <span id="checkout-total" class="font-display text-[2.125rem] font-bold tracking-[-0.02em]">
            {VipShop.format_money(@total, @package.currency)}
          </span>
        </div>
        <p :if={@error} id="checkout-error" class="text-sm text-[var(--sh-danger)]">{@error}</p>
        <button
          id="pay"
          type="submit"
          class="shop-btn shop-btn-accent mt-1 h-14 text-base"
          phx-disable-with={gettext("Opening the payment...")}
        >
          {pay_label(@total, @package, @provider)}<.icon name="hero-arrow-right" class="size-[18px]" />
        </button>
        <.note icon="hero-lock-closed" class="!text-xs">{lock_text(@provider, @settings)}</.note>
      </div>

      <%!-- Phone: the total and the button stay at the bottom of the screen. --%>
      <div class="fixed inset-x-0 bottom-0 z-30 flex flex-col gap-2.5 border-t border-[var(--sh-line)] bg-[var(--sh-ground)] px-4 pt-3 pb-5 sm:hidden">
        <div class="flex items-end justify-between">
          <span class="flex flex-col">
            <span class="text-xs text-[var(--sh-text-3)]">{gettext("Total")}</span>
            <strong class="font-display text-[1.625rem] leading-[1.1] font-bold tracking-[-0.02em]">
              {VipShop.format_money(@total, @package.currency)}
            </strong>
          </span>
          <span :if={@coupon} class="flex flex-col items-end gap-0.5 text-xs">
            <span class="text-[var(--sh-text-2)]">
              {gettext("Subtotal %{amount}",
                amount: VipShop.format_money(@package.price_cents, @package.currency)
              )}
            </span>
            <span class="text-[var(--sh-accent-text)]">
              {gettext("Coupon")} − {VipShop.format_money(@discount, @package.currency)}
            </span>
          </span>
        </div>
        <p :if={@error} class="text-sm text-[var(--sh-danger)]">{@error}</p>
        <button type="submit" class="shop-btn shop-btn-accent h-[3.25rem] text-base">
          {pay_label(@total, @package, @provider)}<.icon name="hero-arrow-right" class="size-[18px]" />
        </button>
      </div>
    </aside>
    """
  end

  # ── Labels ─────────────────────────────────────────────────────────────────

  defp provider_title(provider), do: methods_short(Storefront.methods(provider))

  defp pay_label(total, package, provider) do
    amount = VipShop.format_money(total, package.currency)

    case Storefront.methods(provider) do
      [:pix] -> gettext("Pay %{amount} with Pix", amount: amount)
      [:card] -> gettext("Pay %{amount} by card", amount: amount)
      _several -> gettext("Pay %{amount}", amount: amount)
    end
  end

  defp lock_text(nil, _settings), do: ""

  defp lock_text(provider, settings) do
    gettext("Payment through %{provider}. %{shop} never sees your bank details.",
      provider: Labels.payment_provider(provider),
      shop: shop_name(settings)
    )
  end

  defp vip_note(nil, _zone), do: nil
  defp vip_note(:permanent, _zone), do: gettext("permanent VIP")
  defp vip_note(at, zone), do: gettext("VIP until %{date}", date: ShopFormat.day_month(at, zone))

  defp recipient_note(%{gift?: true}, players, customer) do
    from =
      case players do
        [first | _rest] -> first.player_name || customer_name(customer)
        [] -> customer_name(customer)
      end

    gettext("a gift from %{name}", name: from)
  end

  defp recipient_note(%{player_id: id}, _players, _customer), do: id

  defp current_vip_note(who, nil, _zone),
    do: gettext("%{name} has no active VIP", name: who.name)

  defp current_vip_note(who, :permanent, _zone),
    do: gettext("%{name} already has permanent VIP", name: who.name)

  defp current_vip_note(who, at, zone),
    do:
      gettext("%{name} has VIP until %{date}",
        name: who.name,
        date: ShopFormat.day_month(at, zone)
      )

  defp until_label(:permanent, _zone), do: gettext("permanent")
  defp until_label(at, zone), do: gettext("until %{date}", date: ShopFormat.date(at, zone))

  defp summary_line(package, until, zone) do
    [
      duration(package.duration_days),
      ngettext("%{count} server", "%{count} servers", length(package.servers)),
      until_label(until, zone)
    ]
    |> Enum.join(" · ")
  end

  defp coupon_line(coupon, discount, package, zone) do
    off =
      case coupon.kind do
        "percent" ->
          gettext("%{value}% off", value: coupon.value)

        _fixed ->
          gettext("%{amount} off", amount: VipShop.format_money(discount, package.currency))
      end

    until =
      if coupon.expires_at,
        do: gettext("valid until %{date}", date: ShopFormat.day_month(coupon.expires_at, zone))

    Enum.join(Enum.reject([gettext("Applied: %{off}", off: off), until], &is_nil/1), " · ")
  end
end
