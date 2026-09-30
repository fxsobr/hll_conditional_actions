defmodule HllConditionalActionsWeb.VipShopLive.Tabs do
  @moduledoc """
  The tab row shared by the Loja VIP admin pages (the boards' underlined
  tabs under the header): the setup guide while the shop is not open yet,
  then Visão geral, Pacotes, Compras, Cupons, Vitrine, Pagamentos, Login de
  clientes, E-mail and Regras de compra.

  `on_mount/4` works out once per page what the row needs: how far the
  setup guide is, and where "Pacotes" opens (the first package).
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.VipShop

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :vip_nav, nav())}
  end

  @doc "What the tab row shows, read fresh."
  @spec nav() :: map()
  def nav do
    steps = VipShop.setup_steps()
    done = Enum.count(steps, & &1.done)
    closed = VipShop.settings().closed

    %{
      setup_open: done < length(steps) or closed,
      setup_done: done,
      setup_total: length(steps),
      closed: closed,
      packages_path:
        case VipShop.list_packages() do
          [first | _rest] -> ~p"/vip-shop/packages/#{first.id}/edit"
          [] -> ~p"/vip-shop/packages/new"
        end
    }
  end

  attr :current, :atom, required: true
  attr :nav, :map, default: nil

  def tabs(assigns) do
    assigns = assign(assigns, :nav, assigns.nav || nav())
    overview = if assigns.nav.setup_open, do: ~p"/vip-shop?guide=skip", else: ~p"/vip-shop"

    assigns =
      assign(assigns, :tabs, [
        {:overview, gettext("Overview"), overview},
        {:packages, gettext("Packages"), assigns.nav.packages_path},
        {:purchases, gettext("Purchases"), ~p"/vip-shop/purchases"},
        {:coupons, gettext("Coupons"), ~p"/vip-shop/coupons"},
        {:design, gettext("Storefront"), ~p"/vip-shop/settings/design"},
        {:payments, gettext("Payments"), ~p"/vip-shop/settings/payments"},
        {:login, gettext("Customer sign in"), ~p"/vip-shop/settings/login"},
        {:email, gettext("E-mail"), ~p"/vip-shop/settings/email"},
        {:general, gettext("Purchase rules"), ~p"/vip-shop/settings/general"}
      ])

    ~H"""
    <nav id="vip-shop-tabs" class="vip-tabs" aria-label={gettext("VIP shop")}>
      <.link
        :if={@nav.setup_open}
        id="vip-tab-setup"
        navigate={~p"/vip-shop/settings/setup"}
        class="vip-tab"
        aria-current={@current == :setup && "page"}
      >
        {gettext("Open the shop")}
        <span class="rounded-full bg-secondary px-[0.4375rem] py-px font-mono text-[0.6875rem] font-medium text-subtle">
          {@nav.setup_done}/{@nav.setup_total}
        </span>
      </.link>
      <.link
        :for={{key, label, path} <- @tabs}
        id={"vip-tab-#{key}"}
        navigate={path}
        class="vip-tab"
        aria-current={key == @current && "page"}
      >
        {label}
      </.link>
    </nav>
    """
  end

  @doc "The header button that opens the public shop in a new tab."
  def public_link(assigns),
    do: HllConditionalActionsWeb.VipShopLive.Components.open_shop_link(assigns)
end
