defmodule HllConditionalActionsWeb.ShopLive.Register do
  @moduledoc """
  Creating a shop account with email and password - or with Discord, which
  needs no new password. Once the account exists the form posts itself to
  `/shop/login` (`phx-trigger-action`) so the session cookie is written by a
  real HTTP response.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents
  import HllConditionalActionsWeb.ShopLive.AuthParts

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Settings

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    settings = preview_settings(VipShop.settings(), params)

    cond do
      socket.assigns.current_customer ->
        {:ok, push_navigate(socket, to: ~p"/shop/account")}

      not settings.password_login ->
        {:ok, push_navigate(socket, to: ~p"/shop/login")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Create account"))
         |> assign(:settings, settings)
         |> assign(:discord?, Settings.discord_ready?(settings))
         |> assign(:trigger_submit, false)
         |> assign(:password, "")
         |> assign(:form, to_form(VipShop.change_registration(), as: :customer))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"customer" => params}, socket) do
    changeset = params |> VipShop.change_registration() |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:password, params["password"] || "")
     |> assign(:form, to_form(changeset, as: :customer))}
  end

  def handle_event("save", %{"customer" => params}, socket) do
    case VipShop.register_customer(params) do
      {:ok, _customer} ->
        {:noreply,
         socket
         |> assign(:trigger_submit, true)
         |> assign(:form, to_form(params, as: :customer))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :customer))}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.auth_layout
      current_path={@current_path}
      settings={@settings}
      flash={@flash}
      title={auth_text(@settings, "register_title")}
      lead={auth_text(@settings, "register_subtitle")}
      picture={auth_picture(@settings, "register")}
      back={%{href: ~p"/shop", label: gettext("Back to the shop")}}
    >
      <:aside>
        <.account_cards :if={show_benefits?(@settings)} />
      </:aside>

      <.auth_heading
        title={gettext("Create account")}
        lead={
          if @discord?,
            do:
              gettext(
                "The quickest way is with Discord: no new password, and the VIP tag reaches your profile."
              )
        }
      />

      <.discord_button
        :if={@discord?}
        id="discord-register"
        label={gettext("Create account with Discord")}
      />
      <.or_divider :if={@discord?} />

      <.form
        for={@form}
        id="shop-register-form"
        action={~p"/shop/login"}
        method="post"
        phx-change="validate"
        phx-submit="save"
        phx-trigger-action={@trigger_submit}
        class="flex flex-col gap-3.5"
      >
        <.shop_input
          field={@form[:name]}
          label={gettext("Name")}
          autocomplete="name"
          class="h-[3.125rem]"
          required
        />
        <.shop_input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="email"
          class="h-[3.125rem]"
          phx-debounce="blur"
          required
        />
        <.shop_input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          autocomplete="new-password"
          class="h-[3.125rem]"
          phx-debounce="200"
          required
        >
          <:hint>
            <.strength_meter id="register-strength" password={@password} />
          </:hint>
        </.shop_input>
        <button
          type="submit"
          class={[
            "shop-btn h-[3.25rem] text-[0.9375rem]",
            if(@discord?, do: "shop-btn-secondary", else: "shop-btn-accent")
          ]}
          phx-disable-with={gettext("Creating...")}
        >
          {gettext("Create account with email")}
        </button>
      </.form>

      <p class="text-center text-sm text-[var(--sh-text-2)]">
        {gettext("Already have an account?")}
        <.link navigate={~p"/shop/login"} class="shop-link">{gettext("Sign in")}</.link>
      </p>
    </.auth_layout>
    """
  end
end
