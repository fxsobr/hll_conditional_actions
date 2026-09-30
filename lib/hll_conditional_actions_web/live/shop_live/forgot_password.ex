defmodule HllConditionalActionsWeb.ShopLive.ForgotPassword do
  @moduledoc """
  Asks for an email and sends a password reset link to it. The answer is the
  same whether the email has an account or not, so the form cannot be used
  to find out who is a customer. Requests are limited per email, and the
  resend button waits a minute.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.ShopComponents
  import HllConditionalActionsWeb.ShopLive.AuthParts

  alias HllConditionalActions.RateLimit
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Emails, Settings, Storefront}

  @resend_after 60

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    settings = preview_settings(VipShop.settings(), params)

    {:ok,
     socket
     |> assign(:page_title, gettext("Forgot my password"))
     |> assign(:settings, settings)
     |> assign(:discord?, Settings.discord_ready?(settings))
     |> assign(:sent_to, nil)
     |> assign(:wait, 0)
     |> assign(:form, to_form(%{"email" => ""}, as: :reset))}
  end

  @impl Phoenix.LiveView
  def handle_event("send", %{"reset" => %{"email" => email}}, socket) do
    {:noreply, send_link(socket, email)}
  end

  def handle_event("resend", _params, socket) do
    if socket.assigns.wait == 0 and socket.assigns.sent_to,
      do: {:noreply, send_link(socket, socket.assigns.sent_to)},
      else: {:noreply, socket}
  end

  def handle_event("other-email", _params, socket) do
    {:noreply,
     socket
     |> assign(:sent_to, nil)
     |> assign(:wait, 0)
     |> assign(:form, to_form(%{"email" => ""}, as: :reset))}
  end

  @impl Phoenix.LiveView
  def handle_info(:countdown, socket) do
    wait = max(socket.assigns.wait - 1, 0)
    if wait > 0, do: Process.send_after(self(), :countdown, 1_000)
    {:noreply, assign(socket, :wait, wait)}
  end

  defp send_link(socket, email) do
    email = String.downcase(String.trim(email || ""))

    # Three links an hour per email: enough for a lost email, too few to
    # flood somebody's inbox.
    allowed? = RateLimit.check("shop_reset:email:#{email}", limit: 3, window_ms: 3_600_000) == :ok

    if allowed?, do: VipShop.request_password_reset(email, &url(~p"/shop/reset/#{&1}"))
    if connected?(socket), do: Process.send_after(self(), :countdown, 1_000)

    socket
    |> assign(:sent_to, email)
    |> assign(:wait, @resend_after)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.auth_layout
      current_path={@current_path}
      settings={@settings}
      flash={@flash}
      title={auth_text(@settings, "reset_title")}
      lead={
        gettext(
          "We send a link to your email. Your VIP, your orders and your player stay where they were."
        )
      }
      picture={auth_picture(@settings, "forgot")}
      back={%{href: ~p"/shop/login", label: gettext("Back to sign in")}}
      width="wide"
    >
      <article
        :if={!@sent_to}
        class="shop-raised flex flex-col gap-[1.125rem] rounded-3xl border border-[var(--sh-border-strong)] px-6 py-7 sm:px-8"
      >
        <.auth_heading
          size="md"
          title={gettext("Forgot my password")}
          lead={
            gettext("Type the email you used in the shop. We send a link to create a new password.")
          }
        />
        <.form for={@form} id="forgot-form" phx-submit="send" class="flex flex-col gap-3.5">
          <.shop_input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="email"
            placeholder={gettext("you@example.com")}
            class="h-[3.25rem] !bg-[var(--sh-panel)]"
            required
          />
          <button type="submit" class="shop-btn shop-btn-accent h-14 text-base">
            {gettext("Send link")}<.icon name="hero-arrow-right" class="size-[18px]" />
          </button>
        </.form>
        <div
          :if={@discord?}
          class="flex items-start gap-3 rounded-[0.875rem] bg-[var(--sh-panel)] px-3.5 py-3 text-[0.8125rem] leading-normal text-[var(--sh-text-2)]"
        >
          <HllConditionalActionsWeb.BrandIcons.brand_icon
            name="discord"
            class="mt-0.5 size-4 shrink-0 text-[var(--sh-text-3)]"
          />
          <span>
            {gettext("Created the account with Discord? It has no password.")}
            <a href={~p"/shop/auth/discord"} class="shop-link">{gettext("Sign in with Discord")}</a>.
          </span>
        </div>
      </article>

      <article
        :if={@sent_to}
        id="reset-sent"
        class="shop-raised flex flex-col gap-4 rounded-3xl border border-[var(--sh-border-strong)] px-6 py-7 sm:px-8"
      >
        <div class="flex items-center gap-4">
          <span class="shop-tile flex size-14 shrink-0 items-center justify-center !rounded-[1.125rem]">
            <.icon name="hero-envelope" class="size-6" />
          </span>
          <div class="flex min-w-0 flex-col gap-0.5">
            <h2 class="font-display text-[1.875rem] font-semibold tracking-[-0.03em]">
              {gettext("Email sent")}
            </h2>
            <span class="text-[0.8125rem] text-[var(--sh-text-3)]">
              <span :if={@settings.mail_from_address}>
                {gettext("from")}
                <span class="font-mono text-[var(--sh-text-2)]">{@settings.mail_from_address}</span> ·
              </span>
              {gettext("subject “%{subject}”", subject: reset_subject(@settings))}
            </span>
          </div>
        </div>
        <p class="text-[0.9375rem] leading-normal text-[var(--sh-text-2)]">
          {gettext("If there is an account with")}
          <span class="font-mono text-[var(--sh-text)]">{mask_email(@sent_to)}</span>{gettext(
            ", the link arrives in a few minutes and works for %{minutes} minutes. Did not find it? Look in spam and in Promotions.",
            minutes: Storefront.reset_validity_minutes()
          )}
        </p>
        <div class="flex flex-wrap items-center gap-2.5">
          <button
            type="button"
            id="resend-link"
            phx-click="resend"
            disabled={@wait > 0}
            class="shop-btn h-12 border border-[var(--sh-border)] bg-[var(--sh-panel)] px-[1.125rem] text-sm !font-normal text-[var(--sh-text)] disabled:text-[var(--sh-text-3)]"
          >
            <%= if @wait > 0 do %>
              {gettext("Resend in")}
              <span class="font-mono">{div(@wait, 60)}:{String.pad_leading(
                to_string(rem(@wait, 60)),
                2,
                "0"
              )}</span>
            <% else %>
              {gettext("Resend")}
            <% end %>
          </button>
          <button
            type="button"
            phx-click="other-email"
            class="shop-btn h-12 border border-[var(--sh-border)] bg-[var(--sh-panel)] px-[1.125rem] text-sm !font-normal text-[var(--sh-text)]"
          >
            {gettext("Use another email")}
          </button>
        </div>
      </article>
    </.auth_layout>
    """
  end

  defp reset_subject(settings) do
    settings
    |> Emails.template("reset")
    |> Map.fetch!(:subject)
    |> Emails.render(%{"shop" => shop_name(settings)})
  end
end
