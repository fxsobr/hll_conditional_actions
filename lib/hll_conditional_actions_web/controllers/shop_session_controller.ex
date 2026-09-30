defmodule HllConditionalActionsWeb.ShopSessionController do
  @moduledoc """
  Signs shop customers in and out. The forms are LiveViews
  (`HllConditionalActionsWeb.ShopLive.Login` and `.Register`) that post here,
  because only a real HTTP response can write the session cookie.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.RateLimit
  alias HllConditionalActions.VipShop
  alias HllConditionalActionsWeb.Plugs.LoginRateLimit
  alias HllConditionalActionsWeb.ShopAuth

  # Like the admin sign in: by address against one machine guessing, and by
  # email against many machines guessing the same account.
  def create(conn, %{"customer" => %{"email" => email, "password" => password} = params}) do
    conn = put_return_to(conn, params["return_to"])
    key = email |> to_string() |> String.trim() |> String.downcase()

    limited? =
      RateLimit.check("shop_login:ip:#{LoginRateLimit.client_ip(conn)}",
        limit: 10,
        window_ms: 60_000
      ) != :ok or
        RateLimit.check("shop_login:email:#{key}", limit: 20, window_ms: 3_600_000) != :ok

    cond do
      limited? ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Wait a few minutes and try again."))
        |> redirect(to: ~p"/shop/login")

      VipShop.settings().password_login ->
        password_login(conn, email, password)

      true ->
        conn
        |> put_flash(:error, gettext("Signing in with a password is turned off."))
        |> redirect(to: ~p"/shop/login")
    end
  end

  defp password_login(conn, email, password) do
    case VipShop.authenticate_customer(email, password) do
      {:ok, customer} ->
        RateLimit.reset("shop_login:email:#{String.downcase(String.trim(email))}")
        ShopAuth.log_in(conn, customer)

      :error ->
        conn
        |> put_flash(:error, gettext("Wrong email or password."))
        |> redirect(to: ~p"/shop/login")
    end
  end

  def delete(conn, _params), do: ShopAuth.log_out(conn)

  # Where to land after signing in, when the form says so: only a shop page.
  defp put_return_to(conn, "/shop/" <> _rest = path) do
    if String.contains?(path, ["//", "\\"]),
      do: conn,
      else: put_session(conn, :shop_return_to, path)
  end

  defp put_return_to(conn, _other), do: conn
end
