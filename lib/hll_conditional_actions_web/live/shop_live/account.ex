defmodule HllConditionalActionsWeb.ShopLive.Account do
  @moduledoc """
  A customer's page - "Minha conta": the players linked to the account
  (found by name in CRCON's player history), the VIP running on each server
  for their main player, how they sign in and which emails they get, and
  every order.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents

  alias HllConditionalActions.RateLimit
  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Settings, Storefront}
  alias HllConditionalActionsWeb.ShopFormat

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    customer = socket.assigns.current_customer
    if connected?(socket), do: VipShop.subscribe()
    settings = preview_settings(VipShop.settings(), params)
    players = VipShop.list_customer_players(customer)
    servers = VipShop.shop_servers()

    socket =
      socket
      |> assign(:page_title, gettext("My account"))
      |> assign(:settings, settings)
      |> assign(:discord?, Settings.discord_ready?(settings))
      |> assign(:zone, ShopFormat.zone(servers))
      |> assign(:servers, servers)
      |> assign(:active_packages, VipShop.list_active_packages())
      |> assign(:search, "")
      |> assign(:results, [])
      |> assign(:search_error, false)
      |> assign(:seen, %{})
      |> assign(:editing_email, false)
      |> assign(:email_form, to_form(Storefront.change_email(customer), as: :account))
      |> assign(:preferences, Storefront.preferences(customer))
      |> assign(:players, players)
      |> assign_orders()

    socket =
      if connected?(socket) and players != [] do
        ids = Enum.map(players, & &1.player_id)
        start_async(socket, :seen, fn -> Storefront.last_seen(ids) end)
      else
        socket
      end

    {:ok, socket}
  end

  defp assign_orders(socket) do
    orders =
      socket.assigns.current_customer
      |> VipShop.customer_orders()
      |> Repo.preload(package: :servers)

    assign(socket, :orders, orders)
  end

  @impl Phoenix.LiveView
  def handle_async(:seen, {:ok, seen}, socket), do: {:noreply, assign(socket, :seen, seen)}
  def handle_async(:seen, _failed, socket), do: {:noreply, socket}

  # ── Players ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => term}, socket) do
    case Storefront.search_players(term) do
      {:ok, results} ->
        linked = MapSet.new(socket.assigns.players, & &1.player_id)
        results = results |> Enum.reject(&(&1.player_id in linked)) |> Enum.take(5)
        {:noreply, assign(socket, search: term, results: results, search_error: false)}

      {:error, _reason} ->
        {:noreply, assign(socket, search: term, results: [], search_error: true)}
    end
  end

  def handle_event("link", %{"id" => player_id}, socket) do
    customer = socket.assigns.current_customer

    case Enum.find(socket.assigns.results, &(&1.player_id == player_id)) do
      nil ->
        {:noreply, socket}

      result ->
        {:ok, _link} = VipShop.link_player(customer, result.player_id, result.name)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is linked to your account.", name: result.name))
         |> assign(:seen, Map.put(socket.assigns.seen, result.player_id, result))
         |> assign(players: VipShop.list_customer_players(customer), results: [], search: "")}
    end
  end

  def handle_event("unlink", %{"id" => id}, socket) do
    customer = socket.assigns.current_customer
    :ok = VipShop.unlink_player(customer, id)
    {:noreply, assign(socket, :players, VipShop.list_customer_players(customer))}
  end

  # ── Account ────────────────────────────────────────────────────────────────

  def handle_event("edit-email", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_email, !socket.assigns.editing_email)
     |> assign(
       :email_form,
       to_form(Storefront.change_email(socket.assigns.current_customer), as: :account)
     )}
  end

  def handle_event("save-email", %{"account" => params}, socket) do
    case Storefront.update_email(socket.assigns.current_customer, params) do
      {:ok, customer} ->
        {:noreply,
         socket
         |> assign(:current_customer, customer)
         |> assign(:editing_email, false)
         |> put_flash(:info, gettext("Email changed to %{email}.", email: customer.email))}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(changeset, as: :account))}
    end
  end

  def handle_event("password-link", _params, socket) do
    customer = socket.assigns.current_customer

    cond do
      is_nil(customer.email) ->
        {:noreply, put_flash(socket, :error, gettext("Add an email to the account first."))}

      RateLimit.check("shop_reset:email:#{customer.email}", limit: 3, window_ms: 3_600_000) != :ok ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many links asked. Try again in an hour."))}

      true ->
        VipShop.request_password_reset(customer.email, &url(~p"/shop/reset/#{&1}"))

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("We sent a link to %{email} to set the password.", email: customer.email)
         )}
    end
  end

  def handle_event("disconnect-discord", _params, socket) do
    case Storefront.disconnect_discord(socket.assigns.current_customer) do
      {:ok, customer} ->
        {:noreply,
         socket
         |> assign(:current_customer, customer)
         |> put_flash(:info, gettext("Discord disconnected."))}

      {:error, :only_sign_in} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Discord is how you sign in. Create a password before disconnecting it.")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not disconnect Discord."))}
    end
  end

  def handle_event("preferences", params, socket) do
    attrs = %{
      expiry_reminders: params["expiry_reminders"] == "true",
      receipts: params["receipts"] == "true"
    }

    {:ok, preferences} = Storefront.update_preferences(socket.assigns.current_customer, attrs)
    {:noreply, assign(socket, :preferences, preferences)}
  end

  @impl Phoenix.LiveView
  def handle_info({:vip_order, order}, socket) do
    if order.customer_id == socket.assigns.current_customer.id,
      do: {:noreply, assign_orders(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    main = List.first(assigns.players)

    assigns =
      assigns
      |> assign(:main, main)
      |> assign(:vips, active_vips(assigns.orders, main))
      |> assign(:spent, Storefront.spent(assigns.orders))

    ~H"""
    <.shell
      current_path={@current_path}
      settings={@settings}
      current_customer={@current_customer}
      flash={@flash}
      footer={false}
    >
      <div class="flex flex-col gap-3 px-4 pb-8 sm:gap-5 sm:px-8 lg:px-12 lg:pb-7">
        <div class="flex min-h-16 items-center gap-4">
          <span class="flex min-w-0 flex-col gap-0.5">
            <h1 class="font-display text-[1.625rem] font-semibold tracking-[-0.02em] sm:text-[1.875rem]">
              {gettext("My account")}
            </h1>
            <span class="truncate text-[0.8125rem] text-[var(--sh-text-3)]">
              {customer_name(@current_customer)} · {gettext("customer since %{date}",
                date: ShopFormat.month_year(@current_customer.inserted_at)
              )}
            </span>
          </span>
          <span class="grow"></span>
          <.link
            href={~p"/shop/logout"}
            method="delete"
            id="sign-out"
            class="shop-btn shop-btn-quiet h-11 gap-2 !font-normal px-[1.125rem] text-sm"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-[18px]" />{gettext(
              "Sign out"
            )}
          </.link>
        </div>

        <div class="grid grid-cols-[minmax(0,1fr)] gap-3 sm:gap-5 lg:grid-cols-[28.75rem_minmax(0,1fr)]">
          <.players_panel {assigns} />
          <.vip_panel {assigns} />
          <.account_panel {assigns} />
          <.orders_panel {assigns} />
        </div>
      </div>
    </.shell>
    """
  end

  defp players_panel(assigns) do
    ~H"""
    <section
      id="linked-players"
      aria-labelledby="jogadores"
      class="shop-panel flex min-h-0 flex-col gap-3 rounded-3xl px-5 py-[1.375rem] sm:rounded-[1.75rem] sm:px-6 lg:min-h-[24.75rem]"
    >
      <div class="flex flex-col gap-1">
        <h2 id="jogadores" class="font-display text-xl font-semibold">{gettext("Linked players")}</h2>
        <span class="text-[0.8125rem] text-[var(--sh-text-3)]">
          {gettext("Who gets the VIP when you buy for yourself.")}
        </span>
      </div>

      <div
        :for={{player, index} <- Enum.with_index(@players)}
        id={"player-#{player.id}"}
        class="shop-raised flex items-center gap-3 rounded-2xl px-3.5 py-3"
      >
        <.initials_tile
          name={player.player_name || player.player_id}
          class="size-10 text-[0.8125rem]"
        />
        <span class="flex min-w-0 grow flex-col gap-0.5">
          <span class="flex items-center gap-2">
            <strong class="truncate text-sm font-semibold">{player.player_name || player.player_id}</strong>
            <span
              :if={index == 0}
              class="shop-pill shop-pill-accent px-2 py-0.5 text-[0.6875rem] font-semibold"
            >
              {gettext("main")}
            </span>
          </span>
          <span class="truncate font-mono text-[0.6875rem] text-[var(--sh-text-3)]">
            {player.player_id}<span :if={seen = @seen[player.player_id]}> · {seen_label(seen, @zone)}</span>
          </span>
        </span>
        <button
          type="button"
          phx-click="unlink"
          phx-value-id={player.id}
          data-confirm={gettext("Unlink this player?")}
          aria-label={gettext("Unlink %{name}", name: player.player_name || player.player_id)}
          class="flex size-9 shrink-0 items-center justify-center rounded-full text-[var(--sh-text-3)] transition hover:text-[var(--sh-danger)]"
        >
          <.icon name="hero-x-mark" class="size-[18px]" />
        </button>
      </div>

      <form
        id="player-search"
        phx-change="search"
        phx-submit="search"
        class="mt-1 flex flex-col gap-2"
      >
        <label for="player-search-q" class="text-[0.8125rem] font-medium text-[var(--sh-text-2)]">
          {if @players == [], do: gettext("Link your player"), else: gettext("Link another player")}
        </label>
        <span class="shop-field h-[2.875rem] px-3.5">
          <.icon name="hero-magnifying-glass" class="size-[18px] shrink-0" />
          <input
            type="search"
            id="player-search-q"
            name="q"
            value={@search}
            phx-debounce="400"
            placeholder={gettext("Your in-game name")}
            autocomplete="off"
            class="h-full text-sm"
          />
        </span>
      </form>
      <p :if={@search_error} class="text-sm text-[var(--sh-danger)]">
        {gettext("The player list is unavailable right now. Try again in a moment.")}
      </p>
      <p
        :if={@results == [] and String.length(String.trim(@search)) >= 2 and !@search_error}
        class="text-[0.8125rem] text-[var(--sh-text-3)]"
      >
        {gettext("Nobody with that name played on the servers.")}
      </p>
      <div :if={@results != []} id="search-results" class="flex flex-col gap-0.5">
        <div :for={result <- @results} class="flex items-center gap-3 px-1 py-2">
          <span class="flex min-w-0 grow flex-col gap-0.5">
            <strong class="truncate text-sm font-semibold">{result.name}</strong>
            <span class="truncate text-xs text-[var(--sh-text-3)]">
              <span class="font-mono text-[0.6875rem]">{result.player_id}</span><span :if={
                result.last_seen || result.online?
              }> · {seen_label(result, @zone)}</span>
            </span>
          </span>
          <button
            type="button"
            phx-click="link"
            phx-value-id={result.player_id}
            class="shop-btn shop-btn-secondary h-8 px-3 text-xs !font-normal"
          >
            {gettext("Link")}
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp vip_panel(assigns) do
    renew = renew_package(assigns.vips, assigns.orders, assigns.active_packages)
    assigns = assign(assigns, :renew, renew)

    ~H"""
    <section
      id="active-vips"
      aria-labelledby="vip-ativo"
      class="shop-panel flex min-h-0 flex-col gap-4 rounded-3xl px-5 py-[1.375rem] sm:rounded-[1.75rem] sm:px-6"
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class="flex grow flex-col gap-1">
          <h2 id="vip-ativo" class="font-display text-xl font-semibold">
            {if @main,
              do: gettext("%{name}'s active VIP", name: @main.player_name || @main.player_id),
              else: gettext("Active VIP")}
          </h2>
          <span :if={@settings.stacking == "extend"} class="text-[0.8125rem] text-[var(--sh-text-3)]">
            {gettext("When you renew, the new days add up to the ones left.")}
          </span>
        </span>
        <.link
          :if={@renew && @vips != []}
          navigate={~p"/shop/buy/#{@renew.id}"}
          id="renew-all"
          class="shop-btn shop-btn-accent h-11 gap-2 px-5 text-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" />{ngettext(
            "Renew it",
            "Renew all %{count}",
            length(@vips)
          )}
        </.link>
      </div>

      <div
        :if={@vips == []}
        class="flex grow flex-col items-center justify-center gap-2 rounded-[1.375rem] border border-dashed border-[var(--sh-step)] p-8 text-center"
      >
        <.icon name="hero-star" class="size-7 text-[var(--sh-text-3)]" />
        <p class="text-sm text-[var(--sh-text-2)]">
          {if @players == [],
            do: gettext("Link your player to see its VIP here."),
            else: gettext("No active VIP right now.")}
        </p>
        <.link navigate={~p"/shop#pacotes"} class="shop-link text-sm">
          {gettext("See the packages")}
        </.link>
      </div>

      <div :if={@vips != []} class="grid grow gap-3.5 sm:grid-cols-2 xl:grid-cols-3">
        <.vip_card
          :for={vip <- @vips}
          vip={vip}
          zone={@zone}
          renew={renew_for(vip, @active_packages)}
        />
      </div>
    </section>
    """
  end

  attr :vip, :map, required: true
  attr :zone, :string, required: true
  attr :renew, :any, default: nil

  defp vip_card(assigns) do
    days = assigns.vip.expires_at && ShopFormat.days_left(assigns.vip.expires_at)
    assigns = assigns |> assign(:days, days) |> assign(:soon, is_integer(days) and days <= 3)

    ~H"""
    <article class={[
      "shop-raised flex flex-col overflow-hidden rounded-[1.375rem]",
      @soon && "border border-[color-mix(in_oklab,var(--sh-warn)_30%,transparent)]"
    ]}>
      <div class="shop-art relative h-[6.5rem] shrink-0 !bg-[var(--sh-raised)]">
        <img src={HllConditionalActionsWeb.Ui.server_art(@vip.server)} alt="" class="shop-art-img" />
        <div class="absolute inset-0 -z-10 bg-[linear-gradient(180deg,transparent_20%,color-mix(in_oklab,var(--sh-raised)_95%,transparent)_100%)]">
        </div>
        <strong class="absolute bottom-2.5 left-4 font-display text-[1.0625rem] font-semibold text-[var(--sh-text)]">
          {@vip.server_name}
        </strong>
        <span
          :if={@soon}
          class="shop-glass absolute top-2.5 right-2.5 rounded-full !border-0 px-[9px] py-1 text-[0.6875rem] font-bold text-[var(--sh-img-warn)]"
        >
          {ngettext("ends in %{count} day", "ends in %{count} days", max(@days, 1))}
        </span>
      </div>
      <div class="flex grow flex-col gap-2 px-4 pt-3 pb-4">
        <div class="flex items-baseline justify-between gap-2">
          <span class="text-sm font-semibold">
            {if @vip.expires_at,
              do: gettext("until %{date}", date: ShopFormat.day_month(@vip.expires_at, @zone)),
              else: gettext("Permanent")}
          </span>
          <span
            :if={@days}
            class={[
              "text-xs",
              if(@soon, do: "text-[var(--sh-warn)]", else: "text-[var(--sh-text-2)]")
            ]}
          >
            {ngettext("%{count} day left", "%{count} days left", @days)}
          </span>
        </div>
        <span :if={@vip.progress} class="flex h-1.5 rounded-[3px] bg-[var(--sh-border)]">
          <span
            class={[
              "rounded-[3px]",
              if(@soon, do: "bg-[var(--sh-warn)]", else: "bg-[var(--sh-accent)]")
            ]}
            style={"width: #{@vip.progress}%"}
          ></span>
        </span>
        <span class="text-xs text-[var(--sh-text-3)]">
          {gettext("Order #%{id} · %{package}", id: @vip.order_id, package: @vip.package)}
        </span>
        <span class="grow"></span>
        <.link :if={@renew} navigate={~p"/shop/buy/#{@renew.id}"} class="shop-link text-[0.8125rem]">
          {gettext("Renew")}
        </.link>
      </div>
    </article>
    """
  end

  defp account_panel(assigns) do
    ~H"""
    <section
      id="account-settings"
      aria-labelledby="conta"
      class="shop-panel flex flex-col gap-1 rounded-3xl px-5 py-[1.375rem] sm:rounded-[1.75rem] sm:px-6"
    >
      <h2 id="conta" class="mb-2 font-display text-xl font-semibold">{gettext("Account")}</h2>

      <div class="shop-hairline flex items-center gap-3 border-b py-3">
        <span class="shop-raised flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl">
          <HllConditionalActionsWeb.BrandIcons.brand_icon name="discord" class="size-[18px]" />
        </span>
        <span class="flex min-w-0 grow flex-col gap-0.5">
          <span class="flex items-center gap-2">
            <strong class="text-sm font-semibold">Discord</strong>
            <span
              :if={@current_customer.discord_id}
              class="shop-pill shop-pill-accent px-2 py-0.5 text-[0.6875rem] font-semibold"
            >
              {gettext("connected")}
            </span>
          </span>
          <span class="text-xs text-[var(--sh-text-3)]">
            {if @current_customer.discord_id,
              do: @current_customer.discord_username || gettext("linked account"),
              else: gettext("Not connected")}
          </span>
        </span>
        <button
          :if={@current_customer.discord_id}
          type="button"
          id="disconnect-discord"
          phx-click="disconnect-discord"
          data-confirm={gettext("Disconnect Discord from this account?")}
          class="shop-btn shop-btn-secondary h-8 shrink-0 px-3 text-xs !font-normal"
        >
          {gettext("Disconnect")}
        </button>
        <a
          :if={!@current_customer.discord_id and @discord?}
          href={~p"/shop/auth/discord"}
          class="shop-btn shop-btn-secondary h-8 shrink-0 px-3 text-xs !font-normal"
        >
          {gettext("Connect")}
        </a>
      </div>

      <div class="shop-hairline flex flex-col gap-3 border-b py-3">
        <div class="flex items-center gap-3">
          <span class="shop-raised flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl">
            <.icon name="hero-envelope" class="size-[18px]" />
          </span>
          <span class="flex min-w-0 grow flex-col gap-0.5">
            <strong class="text-sm font-semibold">{gettext("Email")}</strong>
            <span class="truncate text-xs text-[var(--sh-text-3)]">
              {@current_customer.email || gettext("No email yet")}
            </span>
          </span>
          <button
            type="button"
            id="edit-email"
            phx-click="edit-email"
            class="shop-btn shop-btn-secondary h-8 shrink-0 px-3 text-xs !font-normal"
          >
            {cond do
              @editing_email -> gettext("Cancel")
              @current_customer.email -> gettext("Change it")
              true -> gettext("Add")
            end}
          </button>
        </div>
        <.form
          :if={@editing_email}
          for={@email_form}
          id="email-form"
          phx-submit="save-email"
          class="flex flex-col gap-3"
        >
          <.shop_input
            field={@email_form[:email]}
            type="email"
            label={gettext("New email")}
            autocomplete="email"
            class="h-11"
            required
          />
          <.shop_input
            :if={@current_customer.hashed_password}
            field={@email_form[:password]}
            type="password"
            label={gettext("Your password, to confirm")}
            autocomplete="current-password"
            class="h-11"
            required
          />
          <button type="submit" class="shop-btn shop-btn-accent h-11 self-start px-5 text-sm">
            {gettext("Save email")}
          </button>
        </.form>
      </div>

      <div class="shop-hairline flex items-center gap-3 border-b py-3">
        <span class="shop-raised flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl">
          <.icon name="hero-lock-closed" class="size-[18px]" />
        </span>
        <span class="flex min-w-0 grow flex-col gap-0.5">
          <strong class="text-sm font-semibold">{gettext("Password")}</strong>
          <span class="text-xs text-[var(--sh-text-3)]">
            {if @current_customer.hashed_password,
              do: gettext("We email you a link to choose a new one."),
              else: gettext("You sign in with Discord. Create one to use the email too.")}
          </span>
        </span>
        <button
          :if={@current_customer.email}
          type="button"
          id="password-link"
          phx-click="password-link"
          class="shop-btn shop-btn-secondary h-8 shrink-0 px-3 text-xs !font-normal"
        >
          {if @current_customer.hashed_password, do: gettext("Change it"), else: gettext("Create")}
        </button>
      </div>

      <form
        :if={@current_customer.email}
        id="preferences-form"
        phx-change="preferences"
        class="flex flex-col"
      >
        <span class="mt-3.5 mb-1 text-xs tracking-[0.06em] text-[var(--sh-text-3)] uppercase">
          {gettext("Email notices")}
        </span>
        <label class="flex h-10 cursor-pointer items-center gap-3 text-sm">
          <input type="hidden" name="expiry_reminders" value="false" />
          <input
            type="checkbox"
            name="expiry_reminders"
            value="true"
            checked={@preferences.expiry_reminders}
            class="shop-radio rounded"
          />
          {gettext("Before the VIP ends")}
          <span :if={@settings.reminder_days > 0} class="text-xs text-[var(--sh-text-3)]">
            {ngettext("%{count} day before", "%{count} days before", @settings.reminder_days)}
          </span>
        </label>
        <label class="flex h-10 cursor-pointer items-center gap-3 text-sm">
          <input type="hidden" name="receipts" value="false" />
          <input
            type="checkbox"
            name="receipts"
            value="true"
            checked={@preferences.receipts}
            class="shop-radio rounded"
          />
          {gettext("Purchase receipts")}
        </label>
      </form>
    </section>
    """
  end

  defp orders_panel(assigns) do
    ~H"""
    <section
      id="orders"
      aria-labelledby="pedidos"
      class="shop-panel flex min-h-0 flex-col gap-2.5 rounded-3xl px-5 py-[1.375rem] sm:rounded-[1.75rem] sm:px-6"
    >
      <div class="flex flex-wrap items-baseline gap-x-3">
        <h2 id="pedidos" class="grow font-display text-xl font-semibold">{gettext("Orders")}</h2>
        <span :if={@orders != []} class="text-[0.8125rem] text-[var(--sh-text-3)]">
          {ngettext("%{count} order", "%{count} orders", length(@orders))}<span :for={
            {currency, cents} <- @spent
          }> · {gettext("%{amount} in total", amount: VipShop.format_money(cents, currency))}</span>
        </span>
      </div>

      <div
        :if={@orders == []}
        class="flex grow flex-col items-center justify-center gap-2 rounded-[1.375rem] border border-dashed border-[var(--sh-step)] p-8 text-center"
      >
        <.icon name="hero-receipt-percent" class="size-7 text-[var(--sh-text-3)]" />
        <p class="text-sm text-[var(--sh-text-2)]">{gettext("No order yet.")}</p>
      </div>

      <table :if={@orders != []} class="hidden w-full border-collapse text-sm md:table">
        <thead>
          <tr class="text-left text-xs text-[var(--sh-text-3)]">
            <th scope="col" class="shop-hairline border-b pt-2 pr-2 pb-2.5 font-medium">
              {gettext("Purchase")}
            </th>
            <th scope="col" class="shop-hairline border-b px-2 pt-2 pb-2.5 font-medium">
              {gettext("Date")}
            </th>
            <th scope="col" class="shop-hairline border-b px-2 pt-2 pb-2.5 font-medium">
              {gettext("Package")}
            </th>
            <th scope="col" class="shop-hairline border-b px-2 pt-2 pb-2.5 font-medium">
              {gettext("For")}
            </th>
            <th
              scope="col"
              class="shop-hairline hidden border-b px-2 pt-2 pb-2.5 font-medium xl:table-cell"
            >
              {gettext("Payment")}
            </th>
            <th scope="col" class="shop-hairline border-b px-2 pt-2 pb-2.5 text-right font-medium">
              {gettext("Amount")}
            </th>
            <th scope="col" class="shop-hairline border-b pt-2 pb-2.5 pl-4 font-medium">
              {gettext("Status")}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={order <- @orders}
            id={"order-#{order.id}"}
            class="shop-hairline h-[3.375rem] border-b"
          >
            <td class="pr-2">
              <.link
                navigate={~p"/shop/orders/#{order.id}"}
                class="shop-link font-mono text-[0.8125rem] !font-normal"
              >
                #{order.id}
              </.link>
            </td>
            <td class="px-2 whitespace-nowrap text-[var(--sh-text-2)]">
              {ShopFormat.day_time(order.inserted_at, @zone)}
            </td>
            <td class="px-2">{order.package_name}</td>
            <td class="px-2">
              {order.player_name || order.player_id}<span
                :if={order.gift}
                class="text-xs text-[var(--sh-text-3)]"
              > · {gettext("gift")}</span>
            </td>
            <td class="hidden px-2 text-[var(--sh-text-2)] xl:table-cell">
              {Labels.payment_provider(order.provider || "")}
            </td>
            <td class="px-2 text-right whitespace-nowrap">
              {VipShop.format_money(order.amount_cents, order.currency)}
            </td>
            <td class="pl-4"><.order_pill order={order} /></td>
          </tr>
        </tbody>
      </table>

      <div :if={@orders != []} class="flex flex-col md:hidden">
        <.link
          :for={order <- @orders}
          navigate={~p"/shop/orders/#{order.id}"}
          id={"order-card-#{order.id}"}
          class="shop-hairline flex items-center gap-3 border-b py-3"
        >
          <span class="flex min-w-0 grow flex-col gap-0.5">
            <span class="flex items-center gap-2">
              <span class="font-mono text-[0.8125rem] text-[var(--sh-link)]">#{order.id}</span>
              <strong class="truncate text-sm font-semibold">{order.package_name}</strong>
            </span>
            <span class="truncate text-xs text-[var(--sh-text-3)]">
              {ShopFormat.day_time(order.inserted_at, @zone)} · {order.player_name || order.player_id}
            </span>
          </span>
          <span class="flex shrink-0 flex-col items-end gap-1">
            <span class="text-sm">{VipShop.format_money(order.amount_cents, order.currency)}</span>
            <.order_pill order={order} />
          </span>
        </.link>
      </div>
    </section>
    """
  end

  attr :order, :map, required: true

  defp order_pill(assigns) do
    {granted, total} = Storefront.delivery_count(assigns.order)

    {label, tone} =
      case assigns.order.status do
        "pending" ->
          {gettext("Waiting for payment"), :warn}

        "canceled" ->
          {gettext("Canceled"), :muted}

        "fulfilled" ->
          if expired?(assigns.order),
            do: {gettext("Ended"), :muted},
            else: {gettext("Delivered"), :accent}

        "failed" ->
          {gettext("Failed"), :danger}

        "paid" ->
          {gettext("Delivering %{done}/%{total}", done: granted, total: total), :warn}

        _partial ->
          if Storefront.next_delivery_try(assigns.order.id),
            do: {gettext("Delivering %{done}/%{total}", done: granted, total: total), :warn},
            else: {gettext("Delivered %{done}/%{total}", done: granted, total: total), :warn}
      end

    assigns = assign(assigns, label: label, tone: tone)

    ~H"""
    <span class={[
      "shop-pill px-2.5 py-1 text-xs font-semibold whitespace-nowrap",
      @tone == :warn && "shop-pill-warn",
      @tone == :accent && "shop-pill-accent",
      @tone == :muted && "shop-raised text-[var(--sh-text-2)]",
      @tone == :danger &&
        "bg-[color-mix(in_oklab,var(--sh-danger)_14%,transparent)] text-[var(--sh-danger)]"
    ]}>
      {@label}
    </span>
    """
  end

  # ── Data ───────────────────────────────────────────────────────────────────

  defp expired?(order) do
    now = DateTime.utc_now()

    order.grants != [] and
      Enum.all?(order.grants, fn grant ->
        grant.status != "granted" or
          (grant.expires_at && DateTime.compare(grant.expires_at, now) != :gt)
      end)
  end

  # One card per server with the main player's VIP still running, the
  # latest grant of each server winning.
  defp active_vips(_orders, nil), do: []

  defp active_vips(orders, main) do
    now = DateTime.utc_now()
    servers = Map.new(VipShop.shop_servers(), &{&1.id, &1})

    for order <- orders,
        order.player_id == main.player_id,
        grant <- order.grants,
        grant.status == "granted",
        is_nil(grant.expires_at) or DateTime.compare(grant.expires_at, now) == :gt do
      days_left = grant.expires_at && ShopFormat.days_left(grant.expires_at)

      %{
        server: Map.get(servers, grant.server_id) || %{id: grant.server_id, game: :hll},
        server_id: grant.server_id,
        server_name: grant.server_name,
        expires_at: grant.expires_at,
        order_id: order.id,
        package: order.package_name,
        package_id: order.package_id,
        progress:
          if(days_left && order.duration_days,
            do: min(100, max(round(days_left / order.duration_days * 100), 2))
          )
      }
    end
    |> Enum.sort_by(&(&1.expires_at && DateTime.to_unix(&1.expires_at)), :desc)
    |> Enum.uniq_by(& &1.server_id)
    |> Enum.sort_by(& &1.server_name)
  end

  defp renew_for(vip, active_packages),
    do: Enum.find(active_packages, &(&1.id == vip.package_id))

  # "Renovar os 3": the package of the latest order that is still on sale.
  defp renew_package([], _orders, _packages), do: nil

  defp renew_package(vips, _orders, packages) do
    vips
    |> Enum.sort_by(& &1.order_id, :desc)
    |> Enum.find_value(&renew_for(&1, packages))
  end

  defp seen_label(%{online?: true}, _zone), do: gettext("online now")
  defp seen_label(%{last_seen: nil}, _zone), do: ""

  defp seen_label(%{last_seen: at}, zone),
    do: gettext("seen %{when}", when: ShopFormat.seen(at, zone))
end
