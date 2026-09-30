defmodule HllConditionalActionsWeb.ShopLive.Index do
  @moduledoc """
  The storefront: the hero with the busiest server now, then the sections
  the admin enabled in the order they chose (benefits, packages, servers,
  questions, closing call). The servers are read live and refreshed while
  the page is open. Open to everyone; buying asks the visitor to sign in.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Design, LiveServers, Storefront}
  alias HllConditionalActionsWeb.ShopFormat

  @tick_ms 5_000

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    settings = preview_settings(VipShop.settings(), params)
    packages = VipShop.list_active_packages()
    servers = Storefront.servers(packages)

    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     socket
     |> assign(:page_title, shop_name(settings))
     |> assign(:settings, settings)
     |> assign(:design, Design.get(settings.design))
     |> assign(:packages, packages)
     |> assign(:servers, servers)
     |> assign(:zone, ShopFormat.zone(servers))
     |> assign(:methods, Storefront.payment_methods(VipShop.enabled_providers()))
     |> assign(:coupons?, Storefront.coupons_available?())
     |> assign_live(Storefront.live_servers(servers, cached_only: true))
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    now = DateTime.utc_now()
    read_at = socket.assigns.read_at

    socket =
      if is_nil(read_at) or DateTime.diff(now, read_at, :millisecond) >= LiveServers.ttl(),
        do: refresh(socket),
        else: socket

    {:noreply, assign(socket, :now, now)}
  end

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, live}, socket), do: {:noreply, assign_live(socket, live)}
  def handle_async(:live, _failed, socket), do: {:noreply, socket}

  # CRCON is read in the background, so a server that is slow to answer
  # never holds the page.
  defp refresh(socket) do
    servers = socket.assigns.servers

    if connected?(socket) and servers != [],
      do: start_async(socket, :live, fn -> Storefront.live_servers(servers) end),
      else: socket
  end

  defp assign_live(socket, live) do
    socket
    |> assign(:live, live)
    |> assign(:featured, Storefront.featured(live))
    |> assign(:read_at, Storefront.read_at(live))
    |> assign(:now, DateTime.utc_now())
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:sections, Design.enabled_sections(assigns.design))
      |> assign(:cta_package, cta_package(assigns.packages))

    ~H"""
    <.shell
      current_path={@current_path}
      settings={@settings}
      current_customer={@current_customer}
      flash={@flash}
    >
      <.hero
        settings={@settings}
        design={@design}
        packages={@packages}
        servers={@servers}
        live={@live}
        featured={@featured}
        methods={@methods}
        zone={@zone}
      />
      <%= for key <- @sections do %>
        <%= case key do %>
          <% "benefits" -> %>
            <.benefits design={@design} />
          <% "packages" -> %>
            <.packages_section
              design={@design}
              settings={@settings}
              packages={@packages}
              servers={@servers}
              methods={@methods}
              coupons?={@coupons?}
            />
          <% "servers" -> %>
            <.servers_section
              :if={@live != []}
              design={@design}
              live={@live}
              read_at={@read_at}
              now={@now}
            />
          <% "faq" -> %>
            <.faq design={@design} settings={@settings} />
          <% "cta" -> %>
            <.closing_cta
              design={@design}
              settings={@settings}
              package={@cta_package}
              servers={@servers}
              art={cta_art(@settings, @live)}
            />
        <% end %>
      <% end %>
    </.shell>
    """
  end

  # The highlighted package, or the first one.
  defp cta_package([]), do: nil

  defp cta_package(packages),
    do: Enum.find(packages, &(&1.highlight not in [nil, ""])) || List.first(packages)

  # Another server's map than the hero's, so the page does not repeat itself.
  defp cta_art(settings, live) do
    case live do
      [_first, second | _rest] ->
        live_art(second).src

      [only] ->
        live_art(only).src

      [] ->
        if settings.banner_asset_id,
          do: ~p"/shop/assets/#{settings.banner_asset_id}",
          else: "/images/hll/banner.webp"
    end
  end
end
