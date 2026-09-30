defmodule HllConditionalActionsWeb.ShopAuth do
  @moduledoc """
  Signing customers in and out of the VIP shop.

  Customers have their own session key, separate from the admin's, so being
  signed in to one never grants anything in the other. Pages that sell mount
  `:require_customer`; the storefront itself is open to everyone.
  """

  use HllConditionalActionsWeb, :verified_routes
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias HllConditionalActions.VipShop

  @session_key :shop_customer_id

  @doc "Signs a customer in and sends them where they were going."
  def log_in(conn, customer) do
    return_to = get_session(conn, :shop_return_to) || ~p"/shop"

    conn
    |> configure_session(renew: true)
    |> clear_session_keeping_admin()
    |> put_session(@session_key, customer.id)
    |> redirect(to: return_to)
  end

  @doc "Signs the customer out."
  def log_out(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(:shop_return_to)
    |> redirect(to: ~p"/shop")
  end

  # Renewing the session must not sign an admin out of the admin in the same
  # browser - only the shop's own keys are reset.
  defp clear_session_keeping_admin(conn) do
    conn
    |> delete_session(:shop_return_to)
    |> delete_session(:shop_oauth_state)
  end

  @doc "Plug: assigns `:current_customer` from the session."
  def fetch_current_customer(conn, _opts) do
    assign(conn, :current_customer, VipShop.get_customer(get_session(conn, @session_key)))
  end

  @doc """
  Plug: the shop is only served while at least one server installed it; while
  the admin keeps it closed, visitors get a "Coming soon" page.
  """
  def require_open_shop(conn, _opts) do
    settings = if VipShop.shop_servers() != [], do: VipShop.settings()

    cond do
      is_nil(settings) ->
        conn
        |> put_status(:not_found)
        |> put_view(HllConditionalActionsWeb.ErrorHTML)
        |> render(:"404")
        |> halt()

      Map.get(settings, :closed, false) ->
        conn
        |> put_status(:service_unavailable)
        |> put_view(HllConditionalActionsWeb.ShopClosedHTML)
        |> render(:show, settings: settings, page_title: settings.shop_title)
        |> halt()

      true ->
        conn
    end
  end

  @doc false
  def on_mount(:mount_customer, _params, session, socket) do
    {:cont, mount_customer(socket, session)}
  end

  def on_mount(:require_customer, _params, session, socket) do
    socket = mount_customer(socket, session)

    if socket.assigns.current_customer do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :info,
         gettext("Sign in to continue.")
       )
       |> Phoenix.LiveView.redirect(to: ~p"/shop/login")}
    end
  end

  defp mount_customer(socket, session) do
    Phoenix.Component.assign_new(socket, :current_customer, fn ->
      VipShop.get_customer(session[to_string(@session_key)])
    end)
  end
end
