defmodule HllConditionalActionsWeb.VipShopLive.Coupons do
  @moduledoc """
  Discount codes (VipCoupons board): the list filtered by where each code
  stands, with its uses and a switch, what coupons gave in the last 30 days,
  and on the right the coupon being edited - a percentage or a fixed amount
  off, a window of dates, a limit of uses, once per customer, and the
  packages it is good for.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}
  on_mount HllConditionalActionsWeb.VipShopLive.Tabs

  import HllConditionalActionsWeb.VipShopLive.Tabs
  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Coupon, Stats}
  alias HllConditionalActionsWeb.VipShopLive.Overview

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Coupons"))
     |> assign(:currency, VipShop.settings().currency || "BRL")
     |> assign(:packages, VipShop.list_packages())
     |> assign(:filter, :active)
     |> assign(:search, "")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # The list page edits the first coupon of the list, as on the board.
  defp apply_action(socket, :index, _params) do
    case socket.assigns.shown do
      [first | _rest] -> edit(socket, first)
      [] -> edit(socket, %Coupon{})
    end
  end

  defp apply_action(socket, :new, _params), do: edit(socket, %Coupon{})

  defp apply_action(socket, :edit, %{"id" => id}), do: edit(socket, VipShop.get_coupon!(id))

  defp edit(socket, %Coupon{} = coupon) do
    coupon =
      if coupon.kind == "fixed" and coupon.value,
        do: %{coupon | amount: cents_to_decimal(coupon.value)},
        else: coupon

    socket
    |> assign(:coupon, coupon)
    |> assign(:detail, if(coupon.id, do: Stats.coupon_detail(coupon)))
    |> assign(:form, to_form(VipShop.change_coupon(coupon)))
  end

  defp load(socket) do
    coupons = VipShop.list_coupons()
    states = Map.new(coupons, &{&1.id, Coupon.state(&1)})

    counts = %{
      active: Enum.count(states, fn {_id, state} -> state in [:active, :scheduled] end),
      exhausted: Enum.count(states, fn {_id, state} -> state == :exhausted end),
      expired: Enum.count(states, fn {_id, state} -> state == :expired end),
      all: length(coupons)
    }

    socket
    |> assign(:coupons, coupons)
    |> assign(:states, states)
    |> assign(:counts, counts)
    |> assign(:summary, Stats.coupon_summary(30))
    |> assign_shown()
  end

  defp assign_shown(socket) do
    %{coupons: coupons, states: states, filter: filter, search: search} = socket.assigns
    term = search |> String.trim() |> String.upcase()

    shown =
      Enum.filter(coupons, fn coupon ->
        in_filter?(filter, states[coupon.id]) and
          (term == "" or String.contains?(coupon.code, term))
      end)

    assign(socket, :shown, shown)
  end

  defp in_filter?(:active, state), do: state in [:active, :scheduled]
  defp in_filter?(:exhausted, state), do: state == :exhausted
  defp in_filter?(:expired, state), do: state == :expired
  defp in_filter?(:all, _state), do: true

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = Enum.find([:active, :exhausted, :expired, :all], :all, &(to_string(&1) == filter))
    {:noreply, socket |> assign(:filter, filter) |> assign_shown()}
  end

  def handle_event("search", %{"search" => search}, socket),
    do: {:noreply, socket |> assign(:search, search) |> assign_shown()}

  def handle_event("toggle", %{"id" => id}, socket) do
    {:ok, coupon} = id |> VipShop.get_coupon!() |> VipShop.toggle_coupon()
    socket = load(socket)

    socket =
      if socket.assigns.coupon.id == coupon.id, do: edit(socket, coupon), else: socket

    {:noreply, socket}
  end

  def handle_event("generate", _params, socket) do
    code = for _ <- 1..8, into: "", do: <<Enum.random(~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789")>>
    params = Map.put(form_params(socket), "code", code)
    {:noreply, validate(socket, params)}
  end

  def handle_event("validate", %{"coupon" => params}, socket),
    do: {:noreply, validate(socket, params)}

  def handle_event("save", %{"coupon" => params}, socket) do
    case VipShop.save_coupon(socket.assigns.coupon, cast_params(params), actor(socket)) do
      {:ok, coupon} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Coupon saved."))
         |> load()
         |> push_patch(to: ~p"/vip-shop/coupons/#{coupon.id}/edit")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _coupon} = VipShop.delete_coupon(socket.assigns.coupon)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Coupon removed."))
     |> load()
     |> push_patch(to: ~p"/vip-shop/coupons")}
  end

  defp validate(socket, params) do
    changeset =
      socket.assigns.coupon
      |> VipShop.change_coupon(cast_params(params))
      |> Map.put(:action, :validate)

    assign(socket, :form, to_form(changeset))
  end

  defp form_params(socket) do
    form = socket.assigns.form
    %{"code" => form[:code].value, "kind" => form[:kind].value}
  end

  # Dates arrive as days: a coupon starts at the beginning of its first day
  # and ends at the end of its last. Unticked packages send nothing.
  defp cast_params(params) do
    params
    |> Map.update("starts_at", nil, &day_start/1)
    |> Map.update("expires_at", nil, &day_end/1)
    |> Map.update("package_ids", [], fn ids -> ids |> List.wrap() |> Enum.reject(&(&1 == "")) end)
    |> Map.update("amount", nil, fn amount -> amount && String.replace(amount, ",", ".") end)
  end

  defp day_start(date) when is_binary(date) and byte_size(date) == 10, do: date <> "T00:00:00Z"
  defp day_start(other), do: blank(other)
  defp day_end(date) when is_binary(date) and byte_size(date) == 10, do: date <> "T23:59:59Z"
  defp day_end(other), do: blank(other)
  defp blank(""), do: nil
  defp blank(value), do: value

  defp actor(socket), do: socket.assigns.current_user.name || socket.assigns.current_user.username

  defp cents_to_decimal(cents), do: cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Community")}
      greeting={gettext("Coupons")}
      greeting_eyebrow={gettext("Community · VIP shop")}
      scope={false}
    >
      <:actions>
        <.open_shop_link />
        <.link id="new-coupon" patch={~p"/vip-shop/coupons/new"} class="vip-btn">
          <.icon name="hero-plus" class="size-[1.125rem]" />
          <span class="hidden sm:inline">{gettext("New coupon")}</span>
        </.link>
      </:actions>

      <.tabs current={:coupons} nav={@vip_nav} />

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_27.5rem]">
        <.vip_panel label={gettext("Coupons")} class="flex min-h-[40rem] flex-col overflow-hidden">
          <div class="flex flex-col gap-3 border-b border-line-soft px-5 py-4 sm:flex-row sm:items-center">
            <div
              role="radiogroup"
              aria-label={gettext("Filter coupons")}
              class="flex gap-1 self-start overflow-x-auto rounded-full bg-secondary p-1"
            >
              <button
                :for={
                  {key, label} <- [
                    {:active, gettext("In force")},
                    {:exhausted, gettext("Used up")},
                    {:expired, gettext("Expired")},
                    {:all, gettext("All coupons")}
                  ]
                }
                type="button"
                role="radio"
                id={"coupon-filter-#{key}"}
                aria-checked={to_string(key == @filter)}
                phx-click="filter"
                phx-value-filter={key}
                class={[
                  "h-8 shrink-0 whitespace-nowrap rounded-full px-3.5 text-xs",
                  if(key == @filter,
                    do: "bg-inverse font-semibold text-on-inverse",
                    else: "text-subtle hover:text-base-content"
                  )
                ]}
              >
                {label} {Map.fetch!(@counts, key)}
              </button>
            </div>
            <span class="hidden flex-1 sm:block"></span>
            <form id="coupon-search" phx-change="search" phx-submit="search" class="sm:w-60">
              <label class="flex h-10 items-center gap-2 rounded-full border border-base-300 bg-secondary px-3.5 text-muted">
                <.icon name="hero-magnifying-glass" class="size-4" />
                <input
                  type="search"
                  name="search"
                  value={@search}
                  phx-debounce="200"
                  aria-label={gettext("Search coupon")}
                  placeholder={gettext("Search code")}
                  class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[0.8125rem] text-base-content focus:ring-0"
                />
              </label>
            </form>
          </div>

          <div
            role="row"
            class="hidden grid-cols-[9.375rem_4rem_5.375rem_minmax(0,1fr)_7.75rem_3.25rem] gap-3 border-b border-line-soft px-6 py-3 text-xs text-muted md:grid"
          >
            <span role="columnheader">{gettext("Code")}</span>
            <span role="columnheader">{gettext("Type")}</span>
            <span role="columnheader">{gettext("Value")}</span>
            <span role="columnheader">{gettext("Validity")}</span>
            <span role="columnheader">{gettext("Uses")}</span>
            <span role="columnheader">{gettext("Active")}</span>
          </div>

          <div id="coupons" class="flex flex-col gap-1 px-2.5 py-2">
            <p :if={@shown == []} class="px-3 py-10 text-center text-sm text-muted">
              {if @coupons == [],
                do: gettext("No coupon yet. Create a code for an event, a partner or a streamer."),
                else: gettext("No coupon here.")}
            </p>
            <.coupon_row
              :for={coupon <- @shown}
              coupon={coupon}
              state={@states[coupon.id]}
              selected={coupon.id == @coupon.id}
              packages={@packages}
              currency={@currency}
            />
          </div>

          <span class="flex-1"></span>
          <div class="mx-5 mb-5 grid gap-3 sm:grid-cols-3">
            <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-4 py-3.5">
              <span class="text-xs text-subtle">{gettext("Orders with a coupon")}</span>
              <strong class="font-display text-[1.625rem] font-semibold">{@summary.orders}</strong>
              <span class="text-xs text-muted">
                {gettext("of %{count} paid in 30 days", count: @summary.paid_orders)}
              </span>
            </div>
            <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-4 py-3.5">
              <span class="text-xs text-subtle">{gettext("Discount given")}</span>
              <strong class="font-display text-[1.625rem] font-semibold">
                {Overview.short_money(@summary.discount, @currency)}
              </strong>
              <span class="text-xs text-muted">
                {gettext("%{pct}% of revenue", pct: share(@summary.discount, @summary.revenue))}
              </span>
            </div>
            <div class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-4 py-3.5">
              <span class="text-xs text-subtle">{gettext("Best selling coupon")}</span>
              <strong class="truncate pt-1 font-mono text-[1.375rem] font-medium">
                {if @summary.top, do: elem(@summary.top, 0), else: "—"}
              </strong>
              <span class="text-xs text-muted">
                {ngettext(
                  "%{count} use",
                  "%{count} uses",
                  if(@summary.top, do: elem(@summary.top, 1), else: 0)
                )}
              </span>
            </div>
          </div>
        </.vip_panel>

        <.editor
          form={@form}
          coupon={@coupon}
          detail={@detail}
          packages={@packages}
          currency={@currency}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :coupon, :map, required: true
  attr :state, :atom, required: true
  attr :selected, :boolean, default: false
  attr :packages, :list, required: true
  attr :currency, :string, required: true

  defp coupon_row(assigns) do
    assigns = assign(assigns, :dead, assigns.state in [:expired, :off])

    ~H"""
    <div
      role="row"
      id={"coupon-#{@coupon.id}"}
      aria-selected={to_string(@selected)}
      phx-click={JS.patch(~p"/vip-shop/coupons/#{@coupon.id}/edit")}
      class={[
        "grid cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-2 rounded-2xl border px-3.5 py-3 md:grid-cols-[9.375rem_4rem_5.375rem_minmax(0,1fr)_7.75rem_3.25rem]",
        if(@selected,
          do: "vip-selected bg-secondary",
          else: "border-transparent hover:bg-secondary/60"
        )
      ]}
    >
      <span>
        <span class={[
          "rounded-lg px-2.5 py-[0.3125rem] font-mono text-[0.8125rem]",
          if(@dead, do: "bg-secondary text-muted line-through", else: "bg-base-300")
        ]}>
          {@coupon.code}
        </span>
      </span>
      <span class={[
        "hidden text-[0.8125rem] md:block",
        if(@dead, do: "text-muted", else: "text-subtle")
      ]}>
        {if @coupon.kind == "percent", do: "%", else: currency_symbol(@currency)}
      </span>
      <span class={[
        "font-mono text-[0.8125rem] max-md:col-start-2 max-md:row-start-1 max-md:text-right",
        @dead && "text-subtle"
      ]}>
        {if @coupon.kind == "percent",
          do: "#{@coupon.value}%",
          else: money(@coupon.value, @currency)}
      </span>
      <span class="flex min-w-0 flex-col gap-0.5">
        <span class={["text-[0.8125rem]", @dead && "text-subtle"]}><.validity
          coupon={@coupon}
          state={@state}
        /></span>
        <span class={[
          "truncate text-[0.6875rem]",
          if(ends_soon?(@coupon) and not @dead, do: "vip-warn", else: "text-muted")
        ]}>
          {coupon_note(@coupon, @packages)}
        </span>
      </span>
      <span class="flex flex-col gap-[0.3125rem]">
        <span class="flex items-center gap-1.5">
          <span class={["font-mono text-xs", @dead && "text-subtle"]}>
            {@coupon.uses}/{@coupon.max_uses || "∞"}
          </span>
          <span
            :if={@state == :exhausted}
            class="vip-chip vip-chip-warn px-1.5 py-0.5 text-[0.625rem] font-bold"
          >
            {gettext("used up")}
          </span>
        </span>
        <span class={[
          "vip-bar",
          cond do
            @state == :exhausted -> "vip-bar-warn"
            @dead -> "vip-bar-off"
            true -> nil
          end
        ]}>
          <span
            :if={@coupon.max_uses}
            style={"width: #{min(round(@coupon.uses * 100 / @coupon.max_uses), 100)}%"}
          ></span>
        </span>
      </span>
      <%!-- Catches the click on the switch's track, so it does not open the row. --%>
      <span
        class="max-md:col-start-2 max-md:row-start-2 max-md:justify-self-end"
        phx-click={JS.dispatch("vip:noop")}
      >
        <.vip_switch
          name={"active-#{@coupon.id}"}
          id={"coupon-active-#{@coupon.id}"}
          checked={@coupon.active}
          label={gettext("%{code} active", code: @coupon.code)}
          phx-click="toggle"
          phx-value-id={@coupon.id}
        />
      </span>
    </div>
    """
  end

  attr :coupon, :map, required: true
  attr :state, :atom, required: true

  defp validity(assigns) do
    ~H"""
    <%= cond do %>
      <% @state == :expired -> %>
        {gettext("ended")}
        <.vip_time id={"coupon-v-#{@coupon.id}"} at={@coupon.expires_at} format="date" />
      <% @coupon.starts_at && @coupon.expires_at -> %>
        <.vip_time id={"coupon-s-#{@coupon.id}"} at={@coupon.starts_at} format="date" /> –
        <.vip_time id={"coupon-e-#{@coupon.id}"} at={@coupon.expires_at} format="date" />
      <% @coupon.expires_at -> %>
        {gettext("until")}
        <.vip_time id={"coupon-e-#{@coupon.id}"} at={@coupon.expires_at} format="date" />
      <% @coupon.starts_at -> %>
        {gettext("starting")}
        <.vip_time id={"coupon-s-#{@coupon.id}"} at={@coupon.starts_at} format="date" />
      <% true -> %>
        {gettext("no deadline")}
    <% end %>
    """
  end

  # The line under the dates: "vence amanhã" when it ends soon, the team's
  # note, or which packages it is good for.
  defp coupon_note(coupon, packages) do
    cond do
      ends_soon?(coupon) and Coupon.state(coupon) != :expired ->
        ending_note(coupon)

      coupon.note ->
        coupon.note

      coupon.package_ids in [nil, []] ->
        gettext("every package")

      true ->
        packages_note(coupon, packages)
    end
  end

  defp ending_note(coupon) do
    case Date.diff(DateTime.to_date(coupon.expires_at), Date.utc_today()) do
      0 -> gettext("ends today")
      _tomorrow -> gettext("ends tomorrow")
    end
  end

  defp packages_note(coupon, packages) do
    covered = Enum.filter(packages, &(&1.id in coupon.package_ids))
    left_out = Enum.reject(packages, &(&1.id in coupon.package_ids))

    cond do
      length(covered) == 1 ->
        gettext("only %{package}", package: hd(covered).name)

      length(left_out) == 1 ->
        gettext("every package but %{package}", package: hd(left_out).name)

      true ->
        Enum.map_join(covered, ", ", & &1.name)
    end
  end

  defp ends_soon?(%{expires_at: nil}), do: false

  defp ends_soon?(%{expires_at: at}),
    do: DateTime.diff(at, DateTime.utc_now()) in 0..(2 * 86_400)

  attr :form, :any, required: true
  attr :coupon, :map, required: true
  attr :detail, :map, default: nil
  attr :packages, :list, required: true
  attr :currency, :string, required: true

  defp editor(assigns) do
    kind = assigns.form[:kind].value || "percent"
    ids = assigns.form[:package_ids].value || []

    assigns =
      assigns
      |> assign(:kind, kind)
      |> assign(:package_ids, Enum.map(List.wrap(ids), &to_string/1))

    ~H"""
    <.vip_panel
      id="coupon-editor"
      label={@coupon.code || gettext("New coupon")}
      class="flex flex-col overflow-hidden"
    >
      <.form
        for={@form}
        id="coupon-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-1 flex-col"
      >
        <div class="flex items-center gap-3 border-b border-line-soft px-6 py-5">
          <div class="flex min-w-0 flex-1 flex-col gap-1">
            <h2 class="truncate font-mono text-xl font-medium">
              {@coupon.code || gettext("New coupon")}
            </h2>
            <span class="text-[0.8125rem] text-muted">
              <%= if @coupon.id do %>
                {if @coupon.created_by,
                  do: gettext("Created by %{admin} on", admin: @coupon.created_by),
                  else: gettext("Created on")}
                <.vip_time id="coupon-created" at={@coupon.inserted_at} format="date" />
              <% else %>
                {gettext("Not saved yet")}
              <% end %>
            </span>
          </div>
          <button type="submit" id="save-coupon" class="vip-btn vip-btn-cta vip-btn-lg">
            {gettext("Save coupon")}
          </button>
        </div>

        <div class="flex flex-1 flex-col gap-[1.125rem] px-6 py-[1.375rem]">
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Code")}</span>
            <span class="flex gap-2">
              <input
                type="text"
                name="coupon[code]"
                id="coupon-code"
                value={@form[:code].value}
                required
                placeholder="OUTONO15"
                class="vip-field font-mono uppercase tracking-[0.04em]"
              />
              <button
                type="button"
                phx-click="generate"
                class="vip-btn vip-btn-raised !h-11 !rounded-xl !border-line-raised px-4 text-[0.8125rem]"
              >
                {gettext("Generate")}
              </button>
            </span>
            <.errors form={@form} field={:code} />
          </label>

          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">
              {gettext("Note")} <span class="text-muted">{gettext("(only the team sees it)")}</span>
            </span>
            <input
              type="text"
              name="coupon[note]"
              id="coupon-note"
              value={@form[:note].value}
              maxlength="120"
              placeholder={gettext("partnership with the 7DV clan")}
              class="vip-field"
            />
          </label>

          <div class="grid grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)] gap-3">
            <div class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Type")}</span>
              <div
                role="radiogroup"
                aria-label={gettext("Discount type")}
                class="vip-seg !rounded-[0.875rem] border border-line-raised"
              >
                <label class="!h-[2.125rem] !rounded-[0.625rem]">
                  <input
                    type="radio"
                    name="coupon[kind]"
                    value="percent"
                    checked={@kind == "percent"}
                  />
                  {gettext("Percentage")}
                </label>
                <label class="!h-[2.125rem] !rounded-[0.625rem]">
                  <input type="radio" name="coupon[kind]" value="fixed" checked={@kind == "fixed"} />
                  {gettext("Fixed amount")}
                </label>
              </div>
            </div>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Value")}</span>
              <span class="vip-field">
                <%= if @kind == "fixed" do %>
                  <span class="text-[0.8125rem] text-muted">{currency_symbol(@currency)}</span>
                  <input
                    type="text"
                    inputmode="decimal"
                    name="coupon[amount]"
                    id="coupon-amount"
                    value={amount_text(@form[:amount].value, @currency)}
                    class="font-mono"
                  />
                <% else %>
                  <input
                    type="number"
                    min="1"
                    max="100"
                    name="coupon[value]"
                    id="coupon-value"
                    value={@form[:value].value}
                    class="font-mono"
                  />
                  <span class="text-[0.8125rem] text-muted">%</span>
                <% end %>
              </span>
              <.errors form={@form} field={:value} />
            </label>
          </div>

          <div class="grid grid-cols-2 gap-3">
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Valid from")}</span>
              <input
                type="date"
                name="coupon[starts_at]"
                id="coupon-starts"
                value={date_value(@form[:starts_at].value)}
                class="vip-field font-mono"
              />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Until")}</span>
              <input
                type="date"
                name="coupon[expires_at]"
                id="coupon-expires"
                value={date_value(@form[:expires_at].value)}
                class="vip-field font-mono"
              />
            </label>
          </div>

          <div class="grid grid-cols-[9.375rem_minmax(0,1fr)] items-end gap-3">
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Maximum uses")}</span>
              <input
                type="number"
                min="1"
                name="coupon[max_uses]"
                id="coupon-max-uses"
                value={@form[:max_uses].value}
                placeholder="∞"
                class="vip-field font-mono"
              />
            </label>
            <div class="flex h-11 items-center gap-2.5 rounded-xl bg-secondary px-3.5">
              <span class="flex-1 text-[0.8125rem]">{gettext("Once per customer")}</span>
              <.vip_switch
                name="coupon[once_per_customer]"
                id="coupon-once"
                checked={@form[:once_per_customer].value in [true, "true"]}
                label={gettext("Once per customer")}
              />
            </div>
          </div>

          <fieldset class="flex flex-col gap-2">
            <legend class="mb-2 text-[0.8125rem] text-subtle">
              {gettext("Good for")}
              <span class="text-muted">{gettext("(none ticked: every package)")}</span>
            </legend>
            <input type="hidden" name="coupon[package_ids][]" value="" />
            <div class="flex flex-wrap gap-2">
              <label
                :for={package <- @packages}
                class={[
                  "flex h-9 cursor-pointer items-center gap-2 rounded-full pl-2.5 pr-3.5 text-[0.8125rem]",
                  if(to_string(package.id) in @package_ids,
                    do: "vip-ok-box",
                    else: "border border-line-raised bg-secondary text-subtle"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  name="coupon[package_ids][]"
                  value={package.id}
                  checked={to_string(package.id) in @package_ids}
                  class="vip-check !size-4"
                />
                {package.name}
              </label>
            </div>
          </fieldset>

          <div class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3">
            <span class="flex min-w-0 flex-1 flex-col gap-0.5">
              <span class="text-sm">{gettext("Active")}</span>
              <span class="text-xs text-muted">
                {gettext("turning it off pauses the coupon without erasing its history")}
              </span>
            </span>
            <.vip_switch
              name="coupon[active]"
              id="coupon-active"
              checked={@form[:active].value in [true, "true", nil]}
              label={gettext("Coupon active")}
            />
          </div>

          <span class="flex-1"></span>
          <div
            :if={@detail}
            id="coupon-stats"
            class="flex flex-col gap-0.5 border-t border-line-soft pt-3 text-[0.8125rem]"
          >
            <div class="flex justify-between gap-3 px-0.5 py-1.5">
              <span class="text-subtle">{gettext("Uses so far")}</span>
              <span class="truncate font-mono">
                {@detail.uses}<span :if={@detail.by_package != []}> · {Enum.map_join(
                  @detail.by_package,
                  ", ",
                  fn {name, n} -> "#{n} #{name}" end
                )}</span>
              </span>
            </div>
            <div class="flex justify-between px-0.5 py-1.5">
              <span class="text-subtle">{gettext("Discount given")}</span>
              <span class="font-mono">{money(@detail.discount, @currency)}</span>
            </div>
            <div class="flex justify-between px-0.5 py-1.5">
              <span class="text-subtle">{gettext("Sales with the coupon")}</span>
              <span class="font-mono">{money(@detail.sales, @currency)}</span>
            </div>
            <button
              type="button"
              id="delete-coupon"
              phx-click="delete"
              data-confirm={gettext("Remove this coupon? Orders keep the code they used.")}
              class="mt-2 self-start text-xs vip-danger hover:underline"
            >
              {gettext("Remove coupon")}
            </button>
          </div>
        </div>
      </.form>
    </.vip_panel>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true

  defp errors(assigns) do
    ~H"""
    <span
      :for={error <- Keyword.get_values(@form.errors, @field)}
      :if={@form.source.action}
      class="text-xs vip-err"
    >
      {translate_error(error)}
    </span>
    """
  end

  defp amount_text(nil, _currency), do: nil

  defp amount_text(%Decimal{} = amount, currency),
    do: amount_text(Decimal.to_string(amount, :normal), currency)

  defp amount_text(text, currency) when currency in ~w(BRL EUR ARS),
    do: String.replace(to_string(text), ".", ",")

  defp amount_text(text, _currency), do: to_string(text)

  defp date_value(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  defp date_value(<<date::binary-size(10), _rest::binary>>), do: date
  defp date_value(_other), do: nil

  defp share(_part, 0), do: 0

  defp share(part, total) do
    pct = part * 100 / total

    cond do
      pct >= 10 ->
        round(pct)

      Gettext.get_locale(HllConditionalActionsWeb.Gettext) == "pt_BR" ->
        pct |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")

      true ->
        :erlang.float_to_binary(pct, decimals: 1)
    end
  end

  defp currency_symbol("BRL"), do: "R$"
  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(other), do: other
end
