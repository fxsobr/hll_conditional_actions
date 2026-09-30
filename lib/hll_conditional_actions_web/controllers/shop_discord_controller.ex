defmodule HllConditionalActionsWeb.ShopDiscordController do
  @moduledoc """
  "Sign in with Discord" for shop customers, with Discord's OAuth2
  authorization code flow.

  A random `state` kept in the session ties the callback to the browser that
  started it. Only the `identify` and `email` scopes are asked for; the
  access token is used once to read the profile and then dropped.

  In the Discord developer portal the redirect URL to register is
  `https://<your host>/shop/auth/discord/callback`.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Settings
  alias HllConditionalActionsWeb.ShopAuth

  @authorize "https://discord.com/oauth2/authorize"
  @api "https://discord.com/api/v10"

  def request(conn, _params) do
    settings = VipShop.settings()

    if Settings.discord_ready?(settings) do
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      query =
        URI.encode_query(%{
          client_id: settings.discord_client_id,
          redirect_uri: callback_url(conn),
          response_type: "code",
          scope: "identify email",
          state: state,
          prompt: "none"
        })

      conn
      |> put_session(:shop_oauth_state, state)
      |> redirect(external: "#{@authorize}?#{query}")
    else
      conn
      |> put_flash(:error, gettext("Signing in with Discord is not available."))
      |> redirect(to: ~p"/shop/login")
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected = get_session(conn, :shop_oauth_state)
    settings = VipShop.settings()
    conn = delete_session(conn, :shop_oauth_state)

    with true <- is_binary(expected) and Plug.Crypto.secure_compare(expected, state),
         {:ok, token} <- exchange(settings, code, callback_url(conn)),
         {:ok, profile} <- profile(token),
         {:ok, customer} <- VipShop.customer_from_discord(profile) do
      ShopAuth.log_in(conn, customer)
    else
      _failed ->
        conn
        |> put_flash(:error, gettext("Could not sign in with Discord. Please try again."))
        |> redirect(to: ~p"/shop/login")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, gettext("Signing in with Discord was canceled."))
    |> redirect(to: ~p"/shop/login")
  end

  defp exchange(settings, code, redirect_uri) do
    form = [
      client_id: settings.discord_client_id,
      client_secret: settings.discord_client_secret,
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri
    ]

    case req() |> Req.post(url: "#{@api}/oauth2/token", form: form) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      _other -> :error
    end
  end

  defp profile(token) do
    case req() |> Req.get(url: "#{@api}/users/@me", auth: {:bearer, token}) do
      {:ok, %{status: 200, body: %{"id" => _id} = profile}} -> {:ok, profile}
      _other -> :error
    end
  end

  defp req do
    [retry: false]
    |> Req.new()
    |> Req.merge(Application.get_env(:hll_conditional_actions, :discord_oauth_req_options, []))
  end

  defp callback_url(conn), do: url(conn, ~p"/shop/auth/discord/callback")
end
