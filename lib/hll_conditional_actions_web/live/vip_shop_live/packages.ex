defmodule HllConditionalActionsWeb.VipShopLive.Packages do
  @moduledoc """
  The Loja VIP's overview (`/vip-shop`, VipShop board) and its packages
  (VipPackages board): the list on the left, reordered by dragging; the
  package being edited in the middle, with what changed since it was saved;
  and on the right the card as a customer sees it on the storefront.

  A package with several servers grants VIP on all of them. Retiring a
  package archives it: orders keep pointing at it.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}
  on_mount HllConditionalActionsWeb.VipShopLive.Tabs

  import HllConditionalActionsWeb.VipShopLive.Tabs
  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Coupon, Design, Package, Stats}
  alias HllConditionalActionsWeb.VipShopLive.Overview

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: VipShop.subscribe()

    {:ok,
     socket
     |> assign(:page_title, gettext("VIP shop"))
     |> assign(:servers, VipShop.shop_servers())
     |> assign(:currency, VipShop.settings().currency || "BRL")
     |> assign(:overview, nil)
     |> assign(:package, nil)
     |> assign(:form, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  # While the shop is not open the area starts at its setup guide; "Pular o
  # guia" and the Visão geral tab come back with guide=skip.
  defp apply_action(socket, :index, params) do
    if socket.assigns.vip_nav.setup_open and params["guide"] != "skip" do
      push_navigate(socket, to: ~p"/vip-shop/settings/setup")
    else
      assign(socket, overview: Overview.load(), package: nil, form: nil)
    end
  end

  defp apply_action(socket, :new, _params) do
    package = %Package{
      currency: socket.assigns.currency,
      duration_days: 30,
      servers: [],
      active: true,
      position: length(VipShop.list_packages()) + 1
    }

    socket |> load_list() |> start_editing(package)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket |> load_list() |> start_editing(VipShop.get_package!(id))
  end

  defp load_list(socket) do
    settings = VipShop.settings()

    socket
    |> assign(:packages, VipShop.list_packages())
    |> assign(:sales, Stats.package_sales())
    |> assign(:failing, Stats.failing_servers())
    |> assign(:design, Design.get(settings.design))
    |> assign(:coupons, VipShop.list_coupons() |> Enum.filter(&Coupon.usable?/1))
  end

  defp start_editing(socket, package) do
    params = package_params(package)

    socket
    |> assign(:package, package)
    |> assign(:original, params)
    |> assign_params(params)
  end

  # The package as form params, the way the form posts them back.
  defp package_params(%Package{} = package) do
    %{
      "name" => package.name || "",
      "description" => package.description || "",
      "price" => decimal_text(Package.price(package)),
      "compare_at" => decimal_text(Package.compare_at(package)),
      "duration_days" =>
        if(package.duration_days, do: to_string(package.duration_days), else: ""),
      "server_ids" => Enum.map(package.servers || [], &to_string(&1.id)),
      "highlight" => if(package.highlight, do: "true", else: "false"),
      "active" => to_string(package.active),
      "position" => to_string(package.position || 0)
    }
  end

  defp decimal_text(nil), do: ""

  defp decimal_text(decimal),
    do: decimal |> Decimal.to_string(:normal) |> String.replace(".", ",")

  defp assign_params(socket, params, action \\ nil) do
    changeset =
      socket.assigns.package
      |> VipShop.change_package(changeset_params(socket.assigns.package, params))
      |> Map.put(:action, action)

    changed =
      Enum.filter(Map.keys(params), fn key ->
        normalize(key, params[key]) != normalize(key, socket.assigns.original[key])
      end)

    socket
    |> assign(:params, params)
    |> assign(:changed, changed)
    |> assign(:form, to_form(changeset))
  end

  defp normalize("server_ids", ids), do: ids |> List.wrap() |> Enum.sort()
  defp normalize(_key, value), do: value

  # What the schema casts: prices with a dot, the badge's text, blank days
  # as permanent.
  defp changeset_params(package, params) do
    highlight =
      if params["highlight"] == "true",
        do: package.highlight || gettext("Most chosen"),
        else: nil

    %{
      "name" => params["name"],
      "description" => params["description"],
      "price" => String.replace(params["price"] || "", ",", "."),
      "compare_at" => String.replace(params["compare_at"] || "", ",", "."),
      "duration_days" => params["duration_days"],
      "server_ids" => params["server_ids"] || [],
      "highlight" => highlight,
      "active" => params["active"],
      "position" => params["position"],
      "currency" => package.currency
    }
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"package" => params}, socket) do
    {:noreply, assign_params(socket, with_servers(params), :validate)}
  end

  def handle_event("save", %{"package" => params}, socket) do
    params = with_servers(params)
    package = socket.assigns.package

    case VipShop.save_package(package, changeset_params(package, params), actor(socket)) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Package saved."))
         |> assign(:vip_nav, nav())
         |> push_patch(to: ~p"/vip-shop/packages/#{saved.id}/edit")}

      {:error, changeset} ->
        {:noreply, socket |> assign(:params, params) |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("position", %{"delta" => delta}, socket) do
    position = String.to_integer(socket.assigns.params["position"] || "0")
    position = max(position + String.to_integer(delta), 0)
    {:noreply, assign_params(socket, Map.put(socket.assigns.params, "position", "#{position}"))}
  end

  def handle_event("reorder", %{"ids" => ids}, socket) do
    :ok = VipShop.reorder_packages(ids)
    socket = load_list(socket)

    socket =
      case socket.assigns.package do
        %Package{id: id} when not is_nil(id) ->
          fresh = Enum.find(socket.assigns.packages, &(&1.id == id))
          position = to_string(fresh.position)

          socket
          |> assign(:original, Map.put(socket.assigns.original, "position", position))
          |> assign_params(Map.put(socket.assigns.params, "position", position))

        _new ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("duplicate", _params, socket) do
    case VipShop.duplicate_package(socket.assigns.package, actor(socket)) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Package duplicated. The copy is off sale."))
         |> push_patch(to: ~p"/vip-shop/packages/#{copy.id}/edit")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("The package could not be duplicated."))}
    end
  end

  def handle_event("archive", _params, socket) do
    {:ok, _package} = VipShop.archive_package(socket.assigns.package, actor(socket))
    nav = nav()

    {:noreply,
     socket
     |> put_flash(:info, gettext("Package archived. Its orders keep their details."))
     |> assign(:vip_nav, nav)
     |> push_patch(to: nav.packages_path)}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    %{order_id: String.to_integer(id)}
    |> HllConditionalActions.Workers.FulfillVipOrder.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, gettext("Granting the VIP again."))}
  end

  @impl Phoenix.LiveView
  def handle_info({:vip_order, _order}, socket) do
    socket =
      if socket.assigns.live_action == :index and socket.assigns.overview,
        do: assign(socket, :overview, Overview.load()),
        else: socket

    {:noreply, socket}
  end

  # An unchecked group of checkboxes sends nothing; the hidden "" keeps the
  # key so clearing every server is seen as a choice.
  defp with_servers(params) do
    Map.update(params, "server_ids", [], &Enum.reject(List.wrap(&1), fn id -> id == "" end))
  end

  defp actor(socket), do: socket.assigns.current_user.name || socket.assigns.current_user.username

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
      scope={false}
    >
      <:actions>
        <.open_shop_link />
        <.link
          id="new-package"
          patch={~p"/vip-shop/packages/new"}
          class={["vip-btn", if(@live_action == :index, do: "vip-btn-cta", else: "")]}
        >
          <.icon name="hero-plus" class="size-[1.125rem]" />
          <span class="hidden sm:inline">{gettext("New package")}</span>
        </.link>
      </:actions>

      <.tabs current={if @live_action == :index, do: :overview, else: :packages} nav={@vip_nav} />

      <Overview.overview :if={@live_action == :index and @overview} data={@overview} />

      <div
        :if={@live_action in [:new, :edit] and @form}
        class="grid gap-5 lg:grid-cols-[20rem_minmax(0,1fr)] xl:grid-cols-[23.125rem_minmax(0,1fr)_21.25rem]"
      >
        <.package_list
          packages={@packages}
          sales={@sales}
          current={@package.id}
        />
        <.editor
          form={@form}
          params={@params}
          changed={@changed}
          package={@package}
          servers={@servers}
          failing={@failing}
          sales={Map.get(@sales, @package.id, 0)}
          currency={@package.currency || @currency}
        />
        <.preview
          params={@params}
          package={@package}
          servers={@servers}
          design={@design}
          coupons={@coupons}
          currency={@package.currency || @currency}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :packages, :list, required: true
  attr :sales, :map, required: true
  attr :current, :any, default: nil

  defp package_list(assigns) do
    on_sale = Enum.count(assigns.packages, & &1.active)

    assigns =
      assigns
      |> assign(:on_sale, on_sale)
      |> assign(:paused, length(assigns.packages) - on_sale)

    ~H"""
    <.vip_panel label={gettext("Packages")} class="flex flex-col gap-2 px-[1.125rem] py-[1.375rem]">
      <.vip_panel_head title={gettext("Packages")} class="px-1.5 pb-2">
        <span class="text-xs text-muted">
          {gettext("%{on_sale} on sale · %{paused} paused", on_sale: @on_sale, paused: @paused)}
        </span>
      </.vip_panel_head>

      <p :if={@packages == []} class="px-1.5 text-sm text-muted">
        {gettext("No package yet. Fill in the form to create the first.")}
      </p>

      <.sort_list id="packages" event="reorder" class="flex flex-col gap-2">
        <.link
          :for={package <- @packages}
          id={"package-#{package.id}"}
          data-sort-id={package.id}
          patch={~p"/vip-shop/packages/#{package.id}/edit"}
          aria-current={package.id == @current && "true"}
          class={[
            "grid grid-cols-[0.875rem_minmax(0,1fr)_auto] items-center gap-3 rounded-[1.125rem] p-3.5 transition-colors",
            cond do
              package.id == @current -> "vip-selected bg-secondary"
              package.active -> "border border-transparent bg-secondary hover:border-line-raised"
              true -> "border border-dashed border-line-raised"
            end
          ]}
        >
          <.grip label={gettext("Drag to reorder")} />
          <span class="flex min-w-0 flex-col gap-[0.1875rem]">
            <span class="flex min-w-0 items-center gap-2">
              <strong class={[
                "truncate text-[0.9375rem] font-semibold",
                !package.active && "text-subtle"
              ]}>
                {package.name}
              </strong>
              <span
                :if={package.highlight}
                class="vip-chip vip-chip-lime px-[0.4375rem] py-0.5 text-[0.625rem] font-bold"
              >
                {gettext("Featured")}
              </span>
            </span>
            <span class="truncate text-xs text-muted">
              {Overview.duration_label(package.duration_days)} · {servers_label(package.servers)} · {ngettext(
                "%{count} sale",
                "%{count} sales",
                Map.get(@sales, package.id, 0)
              )}
            </span>
          </span>
          <span class="flex flex-col items-end gap-1">
            <span class={["font-mono text-sm", !package.active && "text-subtle"]}>
              {money(package.price_cents, package.currency)}
            </span>
            <.dot_label :if={package.active} class="text-[0.6875rem]">
              {gettext("on sale")}
            </.dot_label>
            <.vip_chip :if={!package.active} class="px-2 py-0.5">{gettext("inactive")}</.vip_chip>
          </span>
        </.link>
      </.sort_list>

      <span class="flex-1"></span>
      <p class="px-1.5 pt-2 text-xs leading-normal text-muted">
        {gettext(
          "Drag by the handle to change the order on the storefront. The order here is the same as the “Order” field."
        )}
      </p>
    </.vip_panel>
    """
  end

  attr :form, :any, required: true
  attr :params, :map, required: true
  attr :changed, :list, required: true
  attr :package, :map, required: true
  attr :servers, :list, required: true
  attr :failing, :map, required: true
  attr :sales, :integer, required: true
  attr :currency, :string, required: true

  defp editor(assigns) do
    selected = assigns.params["server_ids"] || []

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(
        :down,
        Enum.filter(assigns.servers, &(to_string(&1.id) in selected and assigns.failing[&1.id]))
      )

    ~H"""
    <.vip_panel
      id="package-editor"
      label={@package.name || gettext("New package")}
      class="flex min-h-[40rem] flex-col overflow-hidden"
    >
      <.form
        for={@form}
        id="package-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-1 flex-col"
      >
        <div class="flex flex-wrap items-center gap-3 border-b border-line-soft px-6 py-5">
          <div class="flex min-w-0 flex-1 flex-col gap-1">
            <h2 class="truncate font-display text-[1.375rem] font-semibold">
              {if @package.id, do: @package.name, else: gettext("New package")}
            </h2>
            <span class="text-[0.8125rem] text-muted">
              <%= if @package.id do %>
                {@package.updated_by || gettext("Created")} ·
                <.vip_time id="package-updated" at={@package.updated_at} format="datetime" />
              <% else %>
                {gettext("Not saved yet")}
              <% end %>
              <span :if={@changed != []} class="vip-warn">
                · {ngettext("%{count} change", "%{count} changes", length(@changed))}
              </span>
            </span>
          </div>
          <button
            :if={@package.id}
            type="button"
            id="duplicate-package"
            phx-click="duplicate"
            class="vip-btn vip-btn-raised vip-btn-lg !border-base-300"
          >
            {gettext("Duplicate")}
          </button>
          <button
            type="submit"
            id="save-package"
            class="vip-btn vip-btn-cta vip-btn-lg"
            phx-disable-with={gettext("Saving...")}
          >
            {gettext("Save package")}
          </button>
        </div>

        <div class="flex flex-1 flex-col gap-[1.125rem] px-6 py-[1.375rem]">
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Name")}</span>
            <input
              type="text"
              name="package[name]"
              id="package-name"
              value={@params["name"]}
              maxlength="80"
              required
              placeholder={gettext("VIP 30 days")}
              class={["vip-field", "name" in @changed && "vip-changed"]}
            />
            <.field_errors form={@form} field={:name} />
          </label>

          <label class="flex flex-col gap-1.5">
            <span class="flex justify-between text-[0.8125rem] text-subtle">
              {gettext("Description")}
              <span class="font-mono text-[0.6875rem] text-muted">
                {String.length(@params["description"] || "")}/240
              </span>
            </span>
            <textarea
              name="package[description]"
              id="package-description"
              rows="3"
              maxlength="240"
              class={["vip-field", "description" in @changed && "vip-changed"]}
            >{@params["description"]}</textarea>
          </label>

          <div class="grid gap-3 sm:grid-cols-3">
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Price")}</span>
              <span class={["vip-field", "price" in @changed && "vip-changed"]}>
                <span class="text-[0.8125rem] text-muted">{currency_symbol(@currency)}</span>
                <input
                  type="text"
                  inputmode="decimal"
                  name="package[price]"
                  id="package-price"
                  value={@params["price"]}
                  required
                  class="font-mono"
                />
              </span>
              <.field_errors form={@form} field={:price_cents} />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("“Was” price")}</span>
              <span class={["vip-field", "compare_at" in @changed && "vip-changed"]}>
                <span class="text-[0.8125rem] text-muted">{currency_symbol(@currency)}</span>
                <input
                  type="text"
                  inputmode="decimal"
                  name="package[compare_at]"
                  id="package-compare-at"
                  value={@params["compare_at"]}
                  class="font-mono"
                />
              </span>
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Duration")}</span>
              <span class={["vip-field", "duration_days" in @changed && "vip-changed"]}>
                <input
                  type="number"
                  min="1"
                  max="3650"
                  name="package[duration_days]"
                  id="package-days"
                  value={@params["duration_days"]}
                  placeholder="∞"
                  class="font-mono"
                />
                <span class="text-[0.8125rem] text-muted">{gettext("days")}</span>
              </span>
              <.field_errors form={@form} field={:duration_days} />
            </label>
          </div>

          <fieldset class="flex flex-col gap-2">
            <legend class="mb-2 text-[0.8125rem] text-subtle">
              {gettext("Servers where the VIP counts")}
            </legend>
            <p :if={@servers == []} class="text-sm vip-warn">
              {gettext(
                "No server installed the VIP shop yet. Install it from a server's marketplace."
              )}
            </p>
            <input type="hidden" name="package[server_ids][]" value="" />
            <div class="grid gap-2 sm:grid-cols-3">
              <label
                :for={server <- @servers}
                id={"package-server-#{server.id}"}
                class={[
                  "flex min-w-0 cursor-pointer items-center gap-2.5 rounded-[0.875rem] p-3 text-[0.8125rem]",
                  if(to_string(server.id) in @selected,
                    do: "vip-ok-box",
                    else: "border border-line-raised"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  name="package[server_ids][]"
                  value={server.id}
                  checked={to_string(server.id) in @selected}
                  class="vip-check"
                />
                <span class="truncate">{server.name}</span>
              </label>
            </div>
            <.field_errors form={@form} field={:servers} />
            <p
              :for={server <- @down}
              id={"server-down-#{server.id}"}
              class="flex items-start gap-2 text-xs vip-warn"
            >
              <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
              <span>
                {gettext("%{server} not answering since", server: server.name)}
                <.vip_time
                  id={"server-down-at-#{server.id}"}
                  at={@failing[server.id]}
                  format="datetime"
                />. {gettext("New purchases stay pending there until it is back.")}
              </span>
            </p>
          </fieldset>

          <div class="grid gap-2.5 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_9.375rem]">
            <div class="flex items-center gap-2.5 rounded-2xl bg-secondary px-3.5 py-3">
              <span class="flex min-w-0 flex-1 flex-col gap-0.5">
                <span class="text-sm">{gettext("Featured")}</span>
                <span class="text-xs text-muted">{gettext("badge and highlighted card")}</span>
              </span>
              <.vip_switch
                name="package[highlight]"
                id="package-highlight"
                checked={@params["highlight"] == "true"}
                label={gettext("Featured")}
              />
            </div>
            <div class="flex items-center gap-2.5 rounded-2xl bg-secondary px-3.5 py-3">
              <span class="flex min-w-0 flex-1 flex-col gap-0.5">
                <span class="text-sm">{gettext("Active")}</span>
                <span class="text-xs text-muted">{gettext("shows on sale")}</span>
              </span>
              <.vip_switch
                name="package[active]"
                id="package-active"
                checked={@params["active"] == "true"}
                label={gettext("Active")}
              />
            </div>
            <div class="flex flex-col justify-center gap-1.5 rounded-2xl bg-secondary px-3 py-2">
              <span class="text-xs text-muted">{gettext("Order")}</span>
              <input type="hidden" name="package[position]" value={@params["position"]} />
              <div class="flex items-center justify-between">
                <button
                  type="button"
                  phx-click="position"
                  phx-value-delta="-1"
                  aria-label={gettext("Move up")}
                  class="flex size-7 items-center justify-center rounded-full border border-line-raised text-subtle"
                >
                  −
                </button>
                <span class={["font-mono text-[0.9375rem]", "position" in @changed && "vip-warn"]}>
                  {@params["position"]}
                </span>
                <button
                  type="button"
                  phx-click="position"
                  phx-value-delta="1"
                  aria-label={gettext("Move down")}
                  class="flex size-7 items-center justify-center rounded-full border border-line-raised text-subtle"
                >
                  +
                </button>
              </div>
            </div>
          </div>

          <span class="flex-1"></span>
          <div
            :if={@package.id}
            class="flex flex-wrap items-center gap-3 border-t border-line-soft pt-3.5"
          >
            <span class="min-w-0 flex-1 text-xs leading-normal text-muted">
              {ngettext(
                "This package has %{count} sale. Changing the price does not affect who already bought it.",
                "This package has %{count} sales. Changing the price does not affect who already bought it.",
                @sales
              )}
            </span>
            <button
              type="button"
              id="archive-package"
              phx-click="archive"
              data-confirm={
                gettext("Archive this package? It leaves the shop; past orders keep their details.")
              }
              class="vip-btn vip-btn-md vip-btn-ghost !border-base-300 text-[var(--vip-danger-text)]"
            >
              {gettext("Archive package")}
            </button>
          </div>
        </div>
      </.form>
    </.vip_panel>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true

  defp field_errors(assigns) do
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

  attr :params, :map, required: true
  attr :package, :map, required: true
  attr :servers, :list, required: true
  attr :design, :map, required: true
  attr :coupons, :list, required: true
  attr :currency, :string, required: true

  defp preview(assigns) do
    price = cents(assigns.params["price"])
    was = cents(assigns.params["compare_at"])
    days = parse_int(assigns.params["duration_days"])
    selected = assigns.params["server_ids"] || []

    best =
      assigns.coupons
      |> Enum.filter(&(price && Coupon.covers?(&1, assigns.package.id)))
      |> Enum.map(&{&1, Coupon.discount(&1, price)})
      |> Enum.max_by(&elem(&1, 1), fn -> nil end)

    assigns =
      assigns
      |> assign(:price, price)
      |> assign(:was, if(was && price && was > price, do: was))
      |> assign(:days, days)
      |> assign(:saving, if(was && price && was > price, do: round((was - price) * 100 / was)))
      |> assign(:chosen, Enum.filter(assigns.servers, &(to_string(&1.id) in selected)))
      |> assign(:best, best)
      |> assign(:featured, assigns.params["highlight"] == "true")

    ~H"""
    <.vip_panel
      id="package-preview"
      label={gettext("How the customer sees it")}
      class="flex flex-col gap-3.5 p-[1.375rem] lg:col-span-2 xl:col-span-1"
    >
      <.vip_panel_head title={gettext("How the customer sees it")}>
        <.link navigate={~p"/vip-shop/settings/design"} class="text-[0.8125rem] text-primary">
          {theme_label(@design["theme"])}
        </.link>
      </.vip_panel_head>

      <div
        class="vip-shop-preview rounded-[1.375rem] border border-base-300 p-4"
        style={Design.css_vars(@design)}
      >
        <article class={[
          "flex flex-col gap-2.5 rounded-[1.25rem] p-[1.125rem]",
          if(@featured, do: "sp-accent-card", else: "sp-surface border")
        ]}>
          <span class="flex items-center justify-between text-[0.8125rem] opacity-80">
            {Overview.duration_label(@days)}
            <span
              :if={@featured}
              class="rounded-full px-2 py-[0.1875rem] text-[0.6875rem] font-bold"
              style="background: var(--shop-text); color: var(--shop-bg)"
            >
              {@package.highlight || gettext("Most chosen")}
            </span>
          </span>
          <strong class="font-display text-[1.375rem] font-semibold">
            {if @params["name"] in [nil, ""], do: gettext("Package name"), else: @params["name"]}
          </strong>
          <span class="flex items-baseline gap-2">
            <span class="font-display text-[2rem] font-bold leading-tight">
              {if @price, do: money(@price, @currency), else: "—"}
            </span>
            <span :if={@was} class="text-[0.8125rem] line-through opacity-70">
              {money(@was, @currency)}
            </span>
          </span>
          <span
            :if={@saving}
            class="self-start rounded-full px-2 py-[0.1875rem] text-xs font-semibold"
            style="background: color-mix(in oklab, currentColor 12%, transparent)"
          >
            {gettext("save %{pct}%", pct: @saving)}
          </span>
          <span
            :if={@params["description"] not in [nil, ""]}
            class="whitespace-pre-line text-[0.8125rem] leading-normal opacity-85"
          >
            {@params["description"]}
          </span>
          <ul class="flex flex-col gap-1.5 text-[0.8125rem]">
            <li :for={server <- @chosen} class="flex items-center gap-2">
              <.icon name="hero-check" class="size-3.5" />{server.name}
            </li>
          </ul>
          <span
            class="mt-1 flex h-11 items-center justify-center rounded-full text-sm font-semibold"
            style={
              if @featured,
                do: "background: var(--shop-on-accent); color: var(--shop-accent)",
                else: "background: var(--shop-accent); color: var(--shop-on-accent)"
            }
          >
            {gettext("Buy")}
          </span>
        </article>
      </div>

      <div class="flex flex-col gap-0.5 text-[0.8125rem]">
        <div class="flex justify-between border-b border-line-soft px-0.5 py-[0.5625rem]">
          <span class="text-subtle">{gettext("Per month")}</span>
          <span class="font-mono">
            {if @price && @days, do: money(round(@price * 30 / @days), @currency), else: "—"}
          </span>
        </div>
        <div class="flex justify-between border-b border-line-soft px-0.5 py-[0.5625rem]">
          <span class="text-subtle">{gettext("Discount shown")}</span>
          <span class="font-mono">{if @saving, do: "#{@saving}%", else: "—"}</span>
        </div>
        <div class="flex justify-between px-0.5 py-[0.5625rem]">
          <%= if @best do %>
            <span class="text-subtle">
              {gettext("With")} <span class="font-mono">{elem(@best, 0).code}</span>
            </span>
            <span class="font-mono">{money(@price - elem(@best, 1), @currency)}</span>
          <% else %>
            <span class="text-subtle">{gettext("With a coupon")}</span>
            <span class="text-muted">{gettext("no active coupon")}</span>
          <% end %>
        </div>
      </div>
    </.vip_panel>
    """
  end

  defp cents(nil), do: nil

  defp cents(text) do
    case Decimal.parse(String.replace(text, ",", ".")) do
      {decimal, ""} ->
        cents = decimal |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
        if cents > 0, do: cents

      _other ->
        nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp servers_label([server]),
    do: gettext("only %{server}", server: server.name)

  defp servers_label(servers),
    do: ngettext("%{count} server", "%{count} servers", length(servers))

  defp currency_symbol("BRL"), do: "R$"
  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(other), do: other

  @doc "The storefront theme's name, as a link: \"Tema tático\"."
  def theme_label("tactical"), do: gettext("Tactical theme")
  def theme_label("crimson"), do: gettext("Crimson theme")
  def theme_label("midnight"), do: gettext("Midnight theme")
  def theme_label("desert"), do: gettext("Desert theme")
  def theme_label("arctic"), do: gettext("Arctic theme")
  def theme_label(_other), do: gettext("Theme")
end
