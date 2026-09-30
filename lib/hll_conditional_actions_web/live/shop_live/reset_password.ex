defmodule HllConditionalActionsWeb.ShopLive.ResetPassword do
  @moduledoc """
  Choosing a new password from the emailed link, with how long the link
  still works. Once saved, the customer goes on to their account signed in
  with the new password. An expired or used link sends them back to ask for
  a new one.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents
  import HllConditionalActionsWeb.ShopLive.AuthParts

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.Storefront
  alias HllConditionalActionsWeb.ShopFormat

  @impl Phoenix.LiveView
  def mount(%{"token" => token} = params, _session, socket) do
    case VipShop.customer_by_reset_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("This link has expired or was already used. Ask for a new one.")
         )
         |> push_navigate(to: ~p"/shop/reset")}

      customer ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Create a new password"))
         |> assign(:settings, preview_settings(VipShop.settings(), params))
         |> assign(:token, token)
         |> assign(:email, customer.email)
         |> assign(:expires_at, Storefront.reset_expires_at(token))
         |> assign(:params, %{})
         |> assign(:done_at, nil)
         |> assign(:zone, ShopFormat.zone(VipShop.shop_servers()))
         |> assign(:form, to_form(VipShop.change_password(customer), as: :customer))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"customer" => params}, socket) do
    {:noreply, assign(socket, :params, params)}
  end

  def handle_event("save", %{"customer" => params}, socket) do
    case VipShop.reset_password(socket.assigns.token, params) do
      {:ok, customer} ->
        {:noreply,
         socket
         |> assign(:done_at, DateTime.utc_now())
         |> assign(:email, customer.email)
         |> assign(:params, params)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket |> assign(:params, params) |> assign(:form, to_form(changeset, as: :customer))}

      {:error, :invalid_token} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This link has expired. Ask for a new one."))
         |> push_navigate(to: ~p"/shop/reset")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:password, assigns.params["password"] || "")
      |> assign(:confirmation, assigns.params["password_confirmation"] || "")

    ~H"""
    <.auth_layout
      current_path={@current_path}
      settings={@settings}
      flash={@flash}
      title={gettext("New password, same place in the queue.")}
      lead={gettext("Change the password and carry on where you left off. Your VIP keeps working.")}
      picture={auth_picture(@settings, "reset")}
      back={%{href: ~p"/shop/login", label: gettext("Back to sign in")}}
      width="wide"
    >
      <article
        :if={!@done_at}
        class="shop-raised flex flex-col gap-3.5 rounded-3xl border border-[var(--sh-border-strong)] px-6 py-6 sm:px-7"
      >
        <div :if={@expires_at} class="flex justify-end">
          <span class="shop-pill shop-pill-warn flex h-7 items-center gap-1.5 px-2.5 text-xs font-semibold">
            <.icon name="hero-clock" class="size-3.5" />{gettext("expires in")}
            <span class="font-mono">{gettext("%{count} min", count: minutes_left(@expires_at))}</span>
          </span>
        </div>
        <div class="flex flex-col gap-1.5">
          <h2 class="font-display text-[2.125rem] font-semibold tracking-[-0.03em]">
            {gettext("Create a new password")}
          </h2>
          <p class="text-[0.9375rem] leading-normal text-[var(--sh-text-2)]">
            {gettext("For the account")}
            <span class="font-mono text-[var(--sh-text)]">{mask_email(@email)}</span>. {gettext(
              "The link works for %{minutes} minutes and only once.",
              minutes: Storefront.reset_validity_minutes()
            )}
          </p>
        </div>
        <.form
          for={@form}
          id="reset-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-3.5"
        >
          <.shop_input
            field={@form[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            class="h-[3.125rem] !bg-[var(--sh-panel)]"
            phx-debounce="200"
            required
          >
            <:hint>
              <.strength_meter id="reset-strength" password={@password} compact />
            </:hint>
          </.shop_input>
          <.shop_input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Repeat the new password")}
            autocomplete="new-password"
            class="h-[3.125rem] !bg-[var(--sh-panel)]"
            state={if @confirmation != "" and @confirmation == @password, do: "ok"}
            phx-debounce="200"
            required
          >
            <:hint>
              <span
                :if={@confirmation != "" and @confirmation == @password}
                class="text-[var(--sh-accent-text)]"
              >
                {gettext("The two passwords match.")}
              </span>
              <span
                :if={
                  @confirmation != "" and @confirmation != @password and
                    String.length(@confirmation) >= String.length(@password)
                }
                class="text-[var(--sh-danger)]"
              >
                {gettext("The two passwords do not match yet.")}
              </span>
            </:hint>
          </.shop_input>
          <button type="submit" class="shop-btn shop-btn-accent h-14 text-base">
            {gettext("Save new password")}<.icon name="hero-arrow-right" class="size-[18px]" />
          </button>
        </.form>
        <span class="text-[0.8125rem] text-[var(--sh-text-3)]">
          {gettext("Link expired or already used?")}
          <.link navigate={~p"/shop/reset"} class="shop-link">{gettext("Ask for another link")}</.link>
        </span>
      </article>

      <article
        :if={@done_at}
        id="password-changed"
        class="shop-raised flex flex-col gap-3.5 rounded-3xl border border-[var(--sh-border-strong)] px-6 py-6 sm:px-7"
      >
        <div class="flex items-center gap-4">
          <span class="shop-tile flex size-14 shrink-0 items-center justify-center !rounded-[1.125rem]">
            <.icon name="hero-shield-check" class="size-6" />
          </span>
          <div class="flex flex-col gap-0.5">
            <h2 class="font-display text-[1.875rem] font-semibold tracking-[-0.03em]">
              {gettext("Password changed")}
            </h2>
            <span class="text-[0.8125rem] text-[var(--sh-text-3)]">
              {gettext("today")}, <span class="font-mono">{ShopFormat.time(@done_at, @zone)}</span>
            </span>
          </div>
        </div>
        <p class="text-sm leading-normal text-[var(--sh-text-2)]">
          {gettext(
            "Every reset link of the account stopped working. Was it not you? Talk to %{shop} on Discord.",
            shop: shop_name(@settings)
          )}
        </p>
        <form
          id="reset-sign-in"
          action={~p"/shop/login"}
          method="post"
          class="flex flex-wrap items-center gap-2.5"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="customer[email]" value={@email} />
          <input type="hidden" name="customer[password]" value={@password} />
          <input type="hidden" name="customer[return_to]" value={~p"/shop/account"} />
          <button type="submit" class="shop-btn shop-btn-light h-11 gap-2 px-[1.125rem] text-sm">
            {gettext("Go to my account")}<.icon name="hero-arrow-right" class="size-4" />
          </button>
          <.link
            navigate={~p"/shop"}
            class="shop-btn h-11 border border-[var(--sh-border)] px-[1.125rem] text-sm !font-normal"
          >
            {gettext("Back to the shop")}
          </.link>
        </form>
      </article>
    </.auth_layout>
    """
  end

  defp minutes_left(expires_at),
    do: max(ceil(DateTime.diff(expires_at, DateTime.utc_now()) / 60), 0)
end
