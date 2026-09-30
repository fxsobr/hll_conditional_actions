defmodule HllConditionalActionsWeb.ShopLive.Login do
  @moduledoc """
  Signing in to the shop - "Entrar ou criar conta" - with whichever methods
  the admin turned on: Discord (which also creates the account) and/or email
  and password. The form posts to `/shop/login`, since only a real HTTP
  response can write the session cookie.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents
  import HllConditionalActionsWeb.ShopLive.AuthParts

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Settings

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    if socket.assigns.current_customer do
      {:ok, push_navigate(socket, to: ~p"/shop/account")}
    else
      settings = preview_settings(VipShop.settings(), params)

      {:ok,
       socket
       |> assign(:page_title, gettext("Sign in"))
       |> assign(:settings, settings)
       |> assign(:servers, VipShop.shop_servers())
       |> assign(:discord?, Settings.discord_ready?(settings))
       |> assign(:form, to_form(%{"email" => "", "password" => ""}, as: :customer))}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.auth_layout
      current_path={@current_path}
      settings={@settings}
      flash={@flash}
      title={auth_text(@settings, "login_title")}
      lead={auth_text(@settings, "login_subtitle")}
      picture={auth_picture(@settings, "login")}
      back={%{href: ~p"/shop", label: gettext("Back to the shop")}}
    >
      <:aside>
        <.benefit_chips :if={show_benefits?(@settings)} servers={@servers} />
      </:aside>

      <.auth_heading
        title={gettext("Sign in or create an account")}
        lead={
          if @discord?,
            do:
              gettext(
                "With Discord it is quicker: your account is created right away and the VIP tag reaches your profile."
              ),
            else: gettext("Sign in to pick your player, pay and follow your purchases.")
        }
      />

      <.discord_button :if={@discord?} label={gettext("Continue with Discord")} />
      <.or_divider :if={@discord? and @settings.password_login} />

      <.form
        :if={@settings.password_login}
        for={@form}
        id="shop-login-form"
        action={~p"/shop/login"}
        method="post"
        class="flex flex-col gap-3.5"
      >
        <.shop_input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          placeholder={gettext("you@example.com")}
          autocomplete="email"
          required
        />
        <.shop_input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          placeholder={gettext("Your password")}
          autocomplete="current-password"
          required
        >
          <:corner>
            <.link navigate={~p"/shop/reset"} class="shop-link !font-medium">
              {gettext("Forgot my password")}
            </.link>
          </:corner>
        </.shop_input>
        <button
          type="submit"
          class={[
            "shop-btn mt-1 h-[3.25rem] text-[0.9375rem]",
            if(@discord?, do: "shop-btn-secondary", else: "shop-btn-accent")
          ]}
        >
          {gettext("Sign in with email")}
        </button>
      </.form>

      <p :if={@settings.password_login} class="text-center text-sm text-[var(--sh-text-2)]">
        {gettext("No account yet?")}
        <.link navigate={~p"/shop/register"} class="shop-link">
          {gettext("Create an account with email")}
        </.link>
      </p>

      <.note icon="hero-shield-check">
        {gettext(
          "We never ask for your Steam password. After signing in, you pick your player by the name shown in the game."
        )}
      </.note>
    </.auth_layout>
    """
  end
end
