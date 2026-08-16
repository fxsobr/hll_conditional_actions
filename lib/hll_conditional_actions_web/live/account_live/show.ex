defmodule HllConditionalActionsWeb.AccountLive.Show do
  @moduledoc """
  The signed in user's own account: profile, language, two factor, and the
  permissions their role grants.

  Enrolling in two factor happens here in three states — off, showing a QR code
  and waiting for a confirming code, and on. Nothing is stored until the
  confirming code arrives, so a person who closes the page halfway through has
  changed nothing about how they sign in.

  Undoing it asks for a code too. Switching two factor off, or replacing the
  recovery codes, both weaken the account, and a session on its own is not
  proof that the person at the keyboard is its owner — a borrowed laptop would
  otherwise be able to remove the very thing standing in its way.
  """

  use HllConditionalActionsWeb, :live_view

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActionsWeb.Plugs.Locale

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("My account"))
     |> assign(:enrolment, nil)
     |> assign(:enrolment_error, nil)
     |> assign(:fresh_recovery_codes, nil)
     # `:disable` or `:regenerate` while waiting for a code to confirm it.
     |> assign(:pending_action, nil)
     |> assign(:step_up_error, nil)
     |> assign_form(Accounts.update_profile_changeset(socket.assigns.current_user))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.update_profile_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, gettext("Profile updated."))
         |> assign_form(Accounts.update_profile_changeset(user))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # ── Two factor ─────────────────────────────────────────────────────────────

  def handle_event("start_two_factor", _params, socket) do
    {:noreply,
     socket
     |> assign(:enrolment, TwoFactor.start_enrolment(socket.assigns.current_user))
     |> assign(:enrolment_error, nil)}
  end

  def handle_event("cancel_two_factor", _params, socket) do
    # The secret was never stored, so abandoning enrolment is just forgetting
    # what is on screen.
    {:noreply, socket |> assign(:enrolment, nil) |> assign(:enrolment_error, nil)}
  end

  def handle_event("confirm_two_factor", %{"code" => code}, socket) do
    %{enrolment: enrolment, current_user: user} = socket.assigns

    case TwoFactor.confirm(user, enrolment.secret, code) do
      {:ok, user, codes} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:enrolment, nil)
         |> assign(:fresh_recovery_codes, codes)
         |> put_flash(:info, gettext("Two factor sign in is on."))}

      {:error, :invalid_code} ->
        {:noreply,
         assign(
           socket,
           :enrolment_error,
           gettext("That code is not right. Check your app and try again.")
         )}
    end
  end

  # Both of these only ask for the code; `confirm_step_up` is what carries them
  # out, and only after the code checks out.
  def handle_event("ask_" <> action, _params, socket) when action in ~w(disable regenerate) do
    {:noreply,
     socket
     |> assign(:pending_action, String.to_existing_atom(action))
     |> assign(:step_up_error, nil)
     |> assign(:fresh_recovery_codes, nil)}
  end

  def handle_event("cancel_step_up", _params, socket) do
    {:noreply, socket |> assign(:pending_action, nil) |> assign(:step_up_error, nil)}
  end

  # Nothing was asked for, so there is nothing to confirm. Checked before the
  # code is, because verifying spends it: a stray event must not burn a TOTP
  # step, or a recovery code, on an action that does not exist.
  def handle_event("confirm_step_up", _params, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_step_up", %{"code" => code}, socket) do
    %{current_user: user, pending_action: action} = socket.assigns

    case TwoFactor.verify_step_up(user, code) do
      {:ok, user} ->
        {:noreply, socket |> assign(:current_user, user) |> run_step_up(action)}

      {:error, :invalid_code} ->
        {:noreply,
         assign(
           socket,
           :step_up_error,
           gettext("That code is not right. Check your app and try again.")
         )}

      {:error, :rate_limited, seconds} ->
        {:noreply,
         assign(
           socket,
           :step_up_error,
           gettext("Too many wrong codes. Try again in %{seconds} seconds.", seconds: seconds)
         )}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, :fresh_recovery_codes, nil)}
  end

  defp run_step_up(socket, :disable) do
    {:ok, user} = TwoFactor.disable(socket.assigns.current_user)

    socket
    |> assign(:current_user, user)
    |> assign(:pending_action, nil)
    |> assign(:fresh_recovery_codes, nil)
    |> put_flash(:info, gettext("Two factor sign in is off."))
  end

  defp run_step_up(socket, :regenerate) do
    {:ok, user, codes} = TwoFactor.regenerate_recovery_codes(socket.assigns.current_user)

    socket
    |> assign(:current_user, user)
    |> assign(:pending_action, nil)
    |> assign(:fresh_recovery_codes, codes)
    |> put_flash(:info, gettext("New recovery codes. The old ones no longer work."))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :user))

  defp granted_permissions(user) do
    Enum.filter(Permission.all(), &Accounts.can?(user, &1))
  end

  defp locale_label("en"), do: "English"
  defp locale_label("pt_BR"), do: "Português (Brasil)"
  defp locale_label(locale), do: locale

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("My account")}
      page_subtitle={gettext("Your details, language and password")}
    >
      <div class="grid items-start gap-4 lg:grid-cols-2">
        <.card title={gettext("Profile")} icon="hero-user-circle">
          <.form
            for={@form}
            id="profile-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-3"
          >
            <.input field={@form[:name]} type="text" label={gettext("Full name")} />
            <.input field={@form[:email]} type="email" label={gettext("Email")} />

            <p class="text-sm text-subtle">
              {gettext("Username")}: <span class="font-mono">{@current_user.username}</span>
            </p>

            <.button
              type="submit"
              size="sm"
              color="primary"
              phx-disable-with={gettext("Saving...")}
              label={gettext("Save")}
            />
          </.form>

          <div class="border-t border-base-300"></div>

          <.button
            link_type="live_redirect"
            to={~p"/account/password"}
            size="sm"
            variant="ghost"
            color="gray"
            icon="hero-key"
            class="w-fit"
            label={gettext("Change password")}
          />
        </.card>

        <div class="space-y-4">
          <.card title={gettext("Language")} icon="hero-language">
            <div class="flex flex-wrap gap-2">
              <.button
                :for={locale <- Locale.supported()}
                link_type="a"
                to={~p"/locale/#{locale}?return_to=/account"}
                size="sm"
                variant={
                  if(Gettext.get_locale(HllConditionalActionsWeb.Gettext) == locale,
                    do: "solid",
                    else: "ghost"
                  )
                }
                color={
                  if(Gettext.get_locale(HllConditionalActionsWeb.Gettext) == locale,
                    do: "primary",
                    else: "gray"
                  )
                }
                label={locale_label(locale)}
              />
            </div>
          </.card>

          <.card title={gettext("Two factor sign in")} icon="hero-lock-closed">
            <%!-- ── On ───────────────────────────────────────────────── --%>
            <div
              :if={
                TwoFactor.enabled?(@current_user) and is_nil(@enrolment) and
                  is_nil(@pending_action)
              }
              class="space-y-3"
            >
              <p class="flex items-center gap-2 text-sm">
                <.icon name="hero-check-badge" class="size-4 shrink-0 text-success" />
                <span>{gettext("On. Signing in asks for a code from your app.")}</span>
              </p>

              <p class="text-sm text-subtle">
                {ngettext(
                  "%{count} recovery code left.",
                  "%{count} recovery codes left.",
                  TwoFactor.recovery_codes_left(@current_user),
                  count: TwoFactor.recovery_codes_left(@current_user)
                )}
              </p>

              <div class="flex flex-wrap gap-2">
                <%!-- No `data-confirm` on either: the code prompt that
                      follows is the confirmation, and a better one — it asks
                      for something only the owner has. --%>
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  color="gray"
                  icon="hero-arrow-path"
                  phx-click="ask_regenerate"
                  label={gettext("New recovery codes")}
                />

                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  color="danger"
                  icon="hero-lock-open"
                  phx-click="ask_disable"
                  label={gettext("Turn off")}
                />
              </div>
            </div>

            <%!-- ── Confirming a change with a code ──────────────────── --%>
            <div :if={@pending_action} class="space-y-4">
              <p class="text-sm">
                <%= if @pending_action == :disable do %>
                  {gettext(
                    "Turning two factor off leaves your password as the only thing between somebody and this account."
                  )}
                <% else %>
                  {gettext("New recovery codes replace the ones you have now, which stop working.")}
                <% end %>
              </p>

              <p class="text-sm text-subtle">
                {gettext("Type a code from your app to confirm it is you. A recovery code works too.")}
              </p>

              <.alert
                :if={@step_up_error}
                color="danger"
                variant="soft"
                with_icon
                label={@step_up_error}
              />

              <form phx-submit="confirm_step_up" class="space-y-3">
                <.input
                  type="text"
                  id="step_up_code"
                  name="code"
                  value=""
                  label={gettext("Code from your app")}
                  placeholder="123456"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  class="pc-text-input w-full text-center font-mono text-lg tracking-[0.3em]"
                  required
                />

                <div class="flex flex-wrap gap-2">
                  <.button
                    type="submit"
                    size="sm"
                    color={if @pending_action == :disable, do: "danger", else: "primary"}
                    icon="hero-check"
                    label={
                      if @pending_action == :disable,
                        do: gettext("Turn two factor off"),
                        else: gettext("Make new codes")
                    }
                  />

                  <.button
                    type="button"
                    size="sm"
                    variant="ghost"
                    color="gray"
                    phx-click="cancel_step_up"
                    label={gettext("Cancel")}
                  />
                </div>
              </form>
            </div>

            <%!-- ── Off ──────────────────────────────────────────────── --%>
            <div
              :if={
                not TwoFactor.enabled?(@current_user) and is_nil(@enrolment) and
                  is_nil(@pending_action)
              }
              class="space-y-3"
            >
              <p class="text-sm text-subtle">
                {gettext(
                  "Ask for a code from an authenticator app as well as your password. Worth it for an account that can ban players."
                )}
              </p>

              <.button
                type="button"
                size="sm"
                color="primary"
                icon="hero-lock-closed"
                phx-click="start_two_factor"
                class="w-fit"
                label={gettext("Set up two factor")}
              />
            </div>

            <%!-- ── Enrolling ────────────────────────────────────────── --%>
            <div :if={@enrolment} class="space-y-4">
              <ol class="list-decimal space-y-1 pl-4 text-sm text-subtle">
                <li>{gettext("Scan this with your authenticator app.")}</li>
                <li>{gettext("Type the six digit code it starts showing.")}</li>
              </ol>

              <div class="flex justify-center rounded-box border border-base-300 bg-white p-3">
                {Phoenix.HTML.raw(@enrolment.qr_svg)}
              </div>

              <details class="text-sm">
                <summary class="cursor-pointer text-muted">
                  {gettext("Cannot scan it?")}
                </summary>

                <p class="mt-2 text-subtle">
                  {gettext("Type this into your app instead:")}
                </p>

                <p class="mt-1 select-all break-all font-mono text-xs">
                  {HllConditionalActions.Accounts.Totp.readable_secret(@enrolment.secret)}
                </p>
              </details>

              <.alert
                :if={@enrolment_error}
                color="danger"
                variant="soft"
                with_icon
                label={@enrolment_error}
              />

              <form phx-submit="confirm_two_factor" class="space-y-3">
                <.input
                  type="text"
                  id="enrolment_code"
                  name="code"
                  value=""
                  label={gettext("Code from your app")}
                  placeholder="123456"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  class="pc-text-input w-full text-center font-mono text-lg tracking-[0.3em]"
                  required
                />

                <div class="flex flex-wrap gap-2">
                  <.button
                    type="submit"
                    size="sm"
                    color="primary"
                    icon="hero-check"
                    label={gettext("Turn it on")}
                  />

                  <.button
                    type="button"
                    size="sm"
                    variant="ghost"
                    color="gray"
                    phx-click="cancel_two_factor"
                    label={gettext("Cancel")}
                  />
                </div>
              </form>
            </div>

            <%!-- ── The codes, shown once ────────────────────────────── --%>
            <div
              :if={@fresh_recovery_codes}
              class="mt-4 space-y-3 rounded-box border border-warning/40 bg-warning/10 p-4"
            >
              <p class="flex items-center gap-2 text-sm font-medium">
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
                {gettext("Write these down now")}
              </p>

              <p class="text-sm text-subtle">
                {gettext(
                  "Each one signs you in once if you lose your phone. They are not shown again."
                )}
              </p>

              <ul class="grid grid-cols-2 gap-1 font-mono text-sm">
                <li :for={code <- @fresh_recovery_codes} class="select-all">{code}</li>
              </ul>

              <.button
                type="button"
                size="sm"
                variant="ghost"
                color="gray"
                phx-click="dismiss_recovery_codes"
                label={gettext("I have written them down")}
              />
            </div>
          </.card>

          <.card title={gettext("What you can do")} icon="hero-shield-check">
            <p class="text-sm text-subtle">
              {gettext("Role")}: <span class="font-medium">{@current_user.role.name}</span>
            </p>

            <ul class="space-y-1 text-sm">
              <li
                :for={permission <- granted_permissions(@current_user)}
                class="flex items-center gap-2"
              >
                <.icon name="hero-check-circle" class="size-4 text-success" />
                {Labels.permission(permission)}
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
