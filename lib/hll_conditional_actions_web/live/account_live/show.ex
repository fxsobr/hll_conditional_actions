defmodule HllConditionalActionsWeb.AccountLive.Show do
  @moduledoc """
  The signed in user's own account (the Account board): profile and
  language, what the role allows, the browsers signed in (with "Encerrar"),
  two factor, and the password.

  ## Two factor, in three steps

  1. scan the QR code (the secret is kept as a pending enrolment, so a reload
     or tomorrow's visit shows the same code - `Accounts.Enrolments`);
  2. type a code, which proves the app reads it - nothing is stored yet;
  3. save the recovery codes; only "Ligar o 2FA" turns it on.

  Undoing it asks for a code too. Switching two factor off, or replacing the
  recovery codes, both weaken the account, and a session on its own is not
  proof that the person at the keyboard is its owner.

  ## Password

  Changing it asks for the current one and signs out every other session.
  """

  use HllConditionalActionsWeb, :live_view

  import HllConditionalActionsWeb.SettingsComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Enrolments
  alias HllConditionalActions.Accounts.OwnPassword
  alias HllConditionalActions.Accounts.PasswordPolicy
  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActionsWeb.Plugs.Locale

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("My account"))
     |> assign(:session_id, Sessions.id_for(session["session_token"]))
     |> assign(:editing_profile, false)
     |> assign(:setup, pending_setup(user))
     |> assign(:code_error, nil)
     |> assign(:codes_saved, false)
     |> assign(:fresh_recovery_codes, nil)
     # `:disable` or `:regenerate` while waiting for a code to confirm it.
     |> assign(:pending_action, nil)
     |> assign(:step_up_error, nil)
     |> assign_password_form(OwnPassword.changeset(user, %{}))
     |> assign_form(Accounts.update_profile_changeset(user))
     |> load_sessions()}
  end

  defp pending_setup(user) do
    if TwoFactor.enabled?(user) do
      nil
    else
      case Enrolments.pending(user) do
        nil -> nil
        enrolment -> new_setup(user, enrolment.secret)
      end
    end
  end

  defp new_setup(user, secret) do
    %{secret: secret, display: Enrolments.display(user, secret), step: nil, codes: nil}
  end

  # ── Profile ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("edit_profile", _params, socket) do
    {:noreply, update(socket, :editing_profile, &(not &1))}
  end

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
         |> assign(:editing_profile, false)
         |> put_flash(:info, gettext("Profile updated."))
         |> assign_form(Accounts.update_profile_changeset(user))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # ── Sessions ───────────────────────────────────────────────────────────────

  def handle_event("end_session", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         true <- id != socket.assigns.session_id do
      socket.assigns.current_user |> Sessions.revoke(id) |> disconnect()
      {:noreply, socket |> put_flash(:info, gettext("Session ended.")) |> load_sessions()}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("end_other_sessions", _params, socket) do
    ids = Sessions.revoke_others(socket.assigns.current_user, socket.assigns.session_id)
    disconnect(ids)

    {:noreply,
     socket
     |> put_flash(
       :info,
       ngettext("%{count} session ended.", "%{count} sessions ended.", length(ids),
         count: length(ids)
       )
     )
     |> load_sessions()}
  end

  # ── Password ───────────────────────────────────────────────────────────────

  def handle_event("validate_password", %{"password" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> OwnPassword.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_password_form(socket, changeset)}
  end

  def handle_event("change_password", %{"password" => params}, socket) do
    %{current_user: user, session_id: session_id} = socket.assigns

    case OwnPassword.update(user, params, current: true, keep_session_id: session_id) do
      {:ok, user, revoked} ->
        disconnect(revoked)

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(
           :info,
           ngettext(
             "Password changed. %{count} other session was signed out.",
             "Password changed. %{count} other sessions were signed out.",
             length(revoked),
             count: length(revoked)
           )
         )
         |> assign_password_form(OwnPassword.changeset(user, %{}))
         |> load_sessions()}

      {:error, changeset} ->
        {:noreply, assign_password_form(socket, Map.put(changeset, :action, :update))}
    end
  end

  # ── Two factor ─────────────────────────────────────────────────────────────

  def handle_event("start_two_factor", _params, socket) do
    user = socket.assigns.current_user

    if TwoFactor.enabled?(user) do
      {:noreply, socket}
    else
      enrolment = Enrolments.start(user)
      {:noreply, socket |> assign(:setup, new_setup(user, enrolment.secret)) |> reset_setup()}
    end
  end

  def handle_event("cancel_two_factor", _params, socket) do
    Enrolments.clear(socket.assigns.current_user)
    {:noreply, socket |> assign(:setup, nil) |> reset_setup()}
  end

  # Step 2: the code proves the app reads the secret; nothing is stored.
  def handle_event("check_code", %{"code" => code}, %{assigns: %{setup: %{} = setup}} = socket) do
    case Enrolments.check_code(setup.secret, code) do
      {:ok, step} ->
        {:noreply,
         socket
         |> assign(:setup, %{
           setup
           | step: step,
             codes: setup.codes || Enrolments.new_recovery_codes()
         })
         |> assign(:code_error, nil)}

      :error ->
        {:noreply,
         assign(
           socket,
           :code_error,
           gettext("That code is not right. Check your app and try again.")
         )}
    end
  end

  def handle_event("check_code", _params, socket), do: {:noreply, socket}

  def handle_event("codes_saved", params, socket) do
    {:noreply, assign(socket, :codes_saved, params["saved"] == "true")}
  end

  # Step 3: only now is anything stored.
  def handle_event("activate_two_factor", _params, socket) do
    %{setup: setup, codes_saved: saved?, current_user: user} = socket.assigns

    if is_map(setup) and is_integer(setup.step) and saved? do
      {:ok, user} = Enrolments.activate(user, setup.secret, setup.step, setup.codes)

      {:noreply,
       socket
       |> assign(:current_user, Accounts.get_user!(user.id))
       |> assign(:setup, nil)
       |> reset_setup()
       |> put_flash(:info, gettext("Two factor sign in is on."))}
    else
      {:noreply, socket}
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

  defp reset_setup(socket), do: socket |> assign(:code_error, nil) |> assign(:codes_saved, false)

  defp disconnect(session_ids) do
    for id <- session_ids do
      HllConditionalActionsWeb.Endpoint.broadcast(Sessions.socket_id(id), "disconnect", %{})
    end
  end

  defp load_sessions(socket) do
    sessions = Sessions.list(socket.assigns.current_user)
    current = socket.assigns.session_id

    # The browser asking first, then the most recently seen.
    {mine, others} = Enum.split_with(sessions, &(&1.id == current))
    assign(socket, :sessions, mine ++ others)
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :user))

  defp assign_password_form(socket, changeset),
    do: assign(socket, :password_form, to_form(changeset, as: :password))

  defp granted_permissions(user) do
    Enum.filter(Permission.all(), &Accounts.can?(user, &1))
  end

  defp short_permission(:view_servers), do: gettext("View servers")
  defp short_permission(:manage_servers), do: gettext("Manage servers")
  defp short_permission(:view_rules), do: gettext("View rules")
  defp short_permission(:manage_rules), do: gettext("Manage rules")
  defp short_permission(:view_executions), do: gettext("View executions")
  defp short_permission(:view_live_feed), do: gettext("View live feed")
  defp short_permission(:view_stats), do: gettext("View statistics")
  defp short_permission(:view_progression), do: gettext("View progression")
  defp short_permission(:manage_progression), do: gettext("Manage progression")
  defp short_permission(:view_tickets), do: gettext("View tickets")
  defp short_permission(:manage_tickets), do: gettext("Manage tickets")
  defp short_permission(:manage_players), do: gettext("Act on players")
  defp short_permission(:manage_integrations), do: gettext("Manage integrations")
  defp short_permission(:manage_users), do: gettext("Manage users")
  defp short_permission(:manage_roles), do: gettext("Manage roles")
  defp short_permission(permission), do: to_string(permission)

  defp locale_label("en"), do: "English"
  defp locale_label("pt_BR"), do: "Português"
  defp locale_label("es"), do: "Español"
  defp locale_label(locale), do: locale

  defp locales do
    Enum.sort_by(Locale.supported(), &Enum.find_index(["pt_BR", "en", "es"], fn l -> l == &1 end))
  end

  defp current_locale, do: Gettext.get_locale(HllConditionalActionsWeb.Gettext)

  defp server_scope(%{servers: servers}) when is_list(servers) and servers != [],
    do: Enum.map_join(servers, ", ", & &1.name)

  defp server_scope(_user), do: gettext("every server")

  defp two_factor_state(assigns) do
    cond do
      assigns.setup -> :setup
      TwoFactor.enabled?(assigns.current_user) -> :on
      true -> :off
    end
  end

  defp setup_step(%{step: nil}), do: 2
  defp setup_step(%{}), do: 3

  defp device_icon(:phone), do: "hero-device-phone-mobile"
  defp device_icon(:tablet), do: "hero-device-tablet"
  defp device_icon(_desktop), do: "hero-computer-desktop"

  defp device_name(session) do
    case Sessions.describe(session.user_agent) do
      %{browser: nil, os: nil} -> gettext("Unknown browser")
      %{browser: browser, os: nil} -> browser
      %{browser: nil, os: os} -> os
      %{browser: browser, os: os} -> "#{browser} · #{os}"
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :two_factor, two_factor_state(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("My account")}
      crumb={gettext("Settings")}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      global_search={false}
      bell={false}
      scope={false}
    >
      <:actions>
        <.link
          id="account-sign-out"
          href={~p"/logout"}
          method="delete"
          class="flex h-12 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:bg-secondary"
        >
          <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" /> {gettext("Sign out")}
        </.link>
      </:actions>

      <div class="grid gap-5 lg:grid-cols-[23.75rem_minmax(0,1fr)] xl:min-h-[56.25rem]">
        <div class="flex min-h-0 flex-col gap-5">
          <%!-- ── Profile ─────────────────────────────────────────────── --%>
          <section
            id="account-profile"
            aria-label={gettext("Profile")}
            class="flex flex-col gap-4 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-center gap-3.5">
              <.person_avatar user={@current_user} class="size-[3.75rem] text-xl" />
              <div class="flex min-w-0 flex-1 flex-col gap-1">
                <h2 class="truncate font-display text-[1.375rem] font-semibold leading-[1.2]">
                  {@current_user.name || @current_user.username}
                </h2>
                <p class="flex flex-wrap items-center gap-2 text-xs text-muted">
                  <span class="font-mono">{@current_user.username}</span>
                  <span
                    :if={@current_user.role}
                    class="rounded-full bg-primary/12 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-primary"
                  >
                    {role_label(@current_user.role)}
                  </span>
                </p>
              </div>
              <button
                type="button"
                id="account-edit-profile"
                phx-click="edit_profile"
                aria-label={gettext("Edit profile")}
                aria-expanded={to_string(@editing_profile)}
                class="flex size-10 shrink-0 items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle transition-colors hover:text-base-content"
              >
                <.icon name="hero-pencil" class="size-4" />
              </button>
            </div>

            <p :if={not @editing_profile} class="text-[0.8125rem] text-subtle">
              {Enum.join(
                Enum.reject([@current_user.email, server_scope(@current_user)], &is_nil/1),
                " · "
              )}
            </p>

            <.form
              :if={@editing_profile}
              for={@form}
              id="profile-form"
              phx-change="validate"
              phx-submit="save"
              class="settings-form flex flex-col gap-3"
            >
              <.input field={@form[:name]} type="text" label={gettext("Full name")} no_margin />
              <.input field={@form[:email]} type="email" label={gettext("Email")} no_margin />
              <button
                type="submit"
                phx-disable-with={gettext("Saving...")}
                class="h-10 w-fit rounded-full bg-[var(--tone-cta)] px-5 text-sm font-semibold text-[var(--tone-on-cta)]"
              >
                {gettext("Save")}
              </button>
            </.form>

            <div class="flex flex-col gap-2">
              <span id="account-language-label" class="text-[0.8125rem] font-medium text-subtle">
                {gettext("Language")}
              </span>
              <nav
                id="account-language"
                aria-labelledby="account-language-label"
                class="grid auto-cols-fr grid-flow-col gap-1 rounded-full bg-secondary p-1"
              >
                <a
                  :for={locale <- locales()}
                  href={~p"/locale/#{locale}?return_to=/account"}
                  aria-current={locale == current_locale() && "true"}
                  class={[
                    "flex h-[2.125rem] items-center justify-center rounded-full px-3 text-[0.8125rem] transition-colors",
                    if(locale == current_locale(),
                      do: "bg-inverse font-semibold text-on-inverse",
                      else: "text-subtle hover:text-base-content"
                    )
                  ]}
                >
                  {locale_label(locale)}
                </a>
              </nav>
            </div>
          </section>

          <%!-- ── What the role grants ────────────────────────────────── --%>
          <section
            id="account-permissions"
            aria-label={gettext("What your role allows")}
            class="flex flex-col gap-3 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-baseline gap-2">
              <h2 class="flex-1 font-display text-lg font-semibold">
                {gettext("What your role allows")}
              </h2>
              <span class="text-xs text-muted">
                {gettext("%{granted} of %{total}",
                  granted: length(granted_permissions(@current_user)),
                  total: length(Permission.all())
                )}
              </span>
            </div>
            <p :if={granted_permissions(@current_user) == []} class="text-sm text-muted">
              {gettext("Your role grants nothing yet.")}
            </p>
            <ul class="flex flex-wrap gap-1.5">
              <li
                :for={permission <- granted_permissions(@current_user)}
                class={[
                  "rounded-full bg-secondary px-[0.5625rem] py-1 text-xs",
                  if(String.starts_with?(to_string(permission), "manage_"),
                    do: "text-base-content ring-1 ring-inset ring-line-strong",
                    else: "text-subtle"
                  )
                ]}
              >
                {short_permission(permission)}
              </li>
            </ul>
            <p class="text-xs text-muted">
              {gettext("Read only. Roles are changed by an administrator, in")}
              <.link navigate={~p"/roles"} class="text-primary hover:underline">{gettext("Roles")}</.link>.
            </p>
          </section>

          <%!-- ── Sessions ────────────────────────────────────────────── --%>
          <section
            id="account-sessions"
            aria-label={gettext("Sessions")}
            class="flex min-h-0 flex-1 flex-col gap-2.5 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <div class="flex items-baseline gap-2">
              <h2 class="flex-1 font-display text-lg font-semibold">{gettext("Sessions")}</h2>
              <span class="text-xs text-muted">
                {ngettext("%{count} open", "%{count} open", length(@sessions),
                  count: length(@sessions)
                )}
              </span>
            </div>

            <div
              :for={session <- @sessions}
              id={"account-session-#{session.id}"}
              class={[
                "flex items-center gap-3 rounded-2xl px-3 py-2",
                if(session.id == @session_id,
                  do: "bg-secondary",
                  else: "border border-line-soft"
                )
              ]}
            >
              <.icon
                name={device_icon(Sessions.describe(session.user_agent).device)}
                class="size-[1.125rem] shrink-0 text-subtle"
              />
              <span class="flex min-w-0 flex-1 flex-col gap-px">
                <span class="truncate text-[0.8125rem] font-semibold">{device_name(session)}</span>
                <span class="truncate text-xs text-muted">
                  <span class="font-mono">{session.ip || gettext("unknown address")}</span>
                  ·
                  <%= if session.id == @session_id do %>
                    {gettext("now")}
                  <% else %>
                    <.local_time id={"account-session-seen-#{session.id}"} at={session.last_seen_at} />
                  <% end %>
                </span>
              </span>
              <span
                :if={session.id == @session_id}
                class="rounded-full bg-primary/12 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-primary"
              >
                {gettext("this one")}
              </span>
              <button
                :if={session.id != @session_id}
                type="button"
                id={"account-end-session-#{session.id}"}
                phx-click="end_session"
                phx-value-id={session.id}
                class="h-[1.875rem] shrink-0 rounded-full border border-base-300 px-2.5 text-xs transition-colors hover:bg-secondary"
              >
                {gettext("End")}
              </button>
            </div>

            <p :if={@sessions == []} class="text-[0.8125rem] text-muted">
              {gettext("No session is being tracked for this account yet.")}
            </p>

            <span class="flex-1"></span>

            <button
              :if={Enum.any?(@sessions, &(&1.id != @session_id))}
              type="button"
              id="account-end-other-sessions"
              phx-click="end_other_sessions"
              data-confirm={gettext("Sign out every other browser signed in to this account?")}
              class="h-10 rounded-full border border-base-300 bg-secondary text-[0.8125rem] transition-colors hover:bg-base-300"
            >
              {gettext("End the other sessions")}
            </button>
          </section>
        </div>

        <div class="flex min-h-0 flex-col gap-5">
          <%!-- ── Two factor ──────────────────────────────────────────── --%>
          <section
            id="account-two-factor"
            aria-label={gettext("Two-step verification")}
            class="flex min-h-0 flex-1 flex-col gap-[1.125rem] rounded-panel bg-base-100 p-6"
          >
            <div class="flex flex-wrap items-center gap-3">
              <span class={[
                "flex size-11 shrink-0 items-center justify-center rounded-[0.875rem] max-sm:hidden",
                if(@two_factor == :on,
                  do: "bg-primary/12 text-primary",
                  else: "bg-warning/13 text-warning"
                )
              ]}>
                <.icon name="hero-shield-check" class="size-5" />
              </span>
              <div class="flex min-w-0 flex-1 flex-col gap-0.5">
                <div class="flex flex-wrap items-center gap-2.5">
                  <h2 class="font-display text-[1.375rem] font-semibold leading-[1.2]">
                    {gettext("Two-step verification")}
                  </h2>
                  <span class={[
                    "flex h-7 items-center rounded-full px-2.5 text-xs font-semibold",
                    if(@two_factor == :on,
                      do: "bg-primary/12 text-primary",
                      else: "bg-warning/13 text-warning"
                    )
                  ]}>
                    <%= case @two_factor do %>
                      <% :on -> %>
                        {gettext("on")}
                      <% :setup -> %>
                        {gettext("being set up")}
                      <% :off -> %>
                        {gettext("off")}
                    <% end %>
                  </span>
                </div>
                <p class="text-[0.8125rem] text-muted">
                  <%= case @two_factor do %>
                    <% :setup -> %>
                      {gettext("Step %{step} of 3", step: setup_step(@setup))} · {gettext(
                        "2FA only turns on after you save the codes"
                      )}
                    <% :on -> %>
                      {gettext("Signing in asks for a code from your app.")}
                    <% :off -> %>
                      {gettext(
                        "Ask for a code from an authenticator app as well as your password. Worth it for an account that can ban players."
                      )}
                  <% end %>
                </p>
              </div>
              <button
                :if={@two_factor == :setup}
                type="button"
                id="account-cancel-two-factor"
                phx-click="cancel_two_factor"
                class="h-10 rounded-full px-3.5 text-[0.8125rem] text-subtle hover:text-base-content"
              >
                {gettext("Cancel setup")}
              </button>
            </div>

            <%!-- ── Off ────────────────────────────────────────────────── --%>
            <div :if={@two_factor == :off} class="flex flex-col items-start gap-4">
              <ol class="grid w-full gap-3 md:grid-cols-3">
                <li
                  :for={
                    {n, title} <- [
                      {1, gettext("Scan in the app")},
                      {2, gettext("Confirm a code")},
                      {3, gettext("Save the codes")}
                    ]
                  }
                  class="flex items-center gap-2.5 rounded-[1.375rem] bg-secondary p-[1.125rem]"
                >
                  <.step_mark n={n} state={:todo} />
                  <strong class="text-[0.9375rem] font-semibold">{title}</strong>
                </li>
              </ol>
              <button
                type="button"
                id="account-start-two-factor"
                phx-click="start_two_factor"
                class="flex h-12 items-center gap-2 rounded-full bg-[var(--tone-cta)] px-6 text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90"
              >
                <.icon name="hero-lock-closed" class="size-4" /> {gettext("Set up two factor")}
              </button>
            </div>

            <%!-- ── Setting up: three steps side by side ───────────────── --%>
            <div
              :if={@two_factor == :setup}
              id="account-two-factor-setup"
              class="grid min-h-0 flex-1 gap-4 md:grid-cols-3"
            >
              <div class="flex flex-col gap-3 rounded-[1.375rem] bg-secondary p-[1.125rem]">
                <div class="flex items-center gap-2.5">
                  <.step_mark n={1} state={:done} />
                  <strong class="text-[0.9375rem] font-semibold">{gettext("Scan in the app")}</strong>
                </div>
                <p class="text-[0.8125rem] leading-[1.45] text-subtle">
                  {gettext("Google Authenticator, 1Password, Aegis or another TOTP app.")}
                </p>
                <div class="mx-auto w-[10.5rem] rounded-2xl bg-white p-2 [&_svg]:h-auto [&_svg]:w-full">
                  {Phoenix.HTML.raw(@setup.display.qr_svg)}
                </div>
                <span class="text-xs text-muted">{gettext("No camera? Type the key:")}</span>
                <div class="flex items-center gap-2 rounded-xl border border-line-raised bg-base-100 py-2 pl-3 pr-2">
                  <span
                    id="account-two-factor-key"
                    class="min-w-0 flex-1 select-all break-all font-mono text-[0.8125rem] tracking-[0.04em]"
                  >
                    {@setup.display.readable}
                  </span>
                  <button
                    type="button"
                    id="account-copy-key"
                    phx-hook=".CopyText"
                    data-text={@setup.display.readable}
                    aria-label={gettext("Copy key")}
                    class="flex size-8 shrink-0 items-center justify-center rounded-[0.625rem] bg-secondary text-subtle hover:text-base-content"
                  >
                    <.icon name="hero-document-duplicate" class="size-4" />
                  </button>
                </div>
              </div>

              <div class="flex flex-col gap-3 rounded-[1.375rem] bg-secondary p-[1.125rem]">
                <div class="flex items-center gap-2.5">
                  <.step_mark n={2} state={if @setup.step, do: :done, else: :current} />
                  <strong class="text-[0.9375rem] font-semibold">{gettext("Confirm a code")}</strong>
                </div>
                <p class="text-[0.8125rem] leading-[1.45] text-subtle">
                  {gettext("Type the 6 digits the app shows now, to prove the QR code was read.")}
                </p>
                <form id="enrolment-form" phx-submit="check_code" class="flex flex-col gap-3">
                  <.digit_boxes id="enrolment-digits" ok={is_integer(@setup.step)} />
                  <button :if={is_nil(@setup.step)} type="submit" class="sr-only">
                    {gettext("Check code")}
                  </button>
                </form>
                <p
                  :if={@setup.step}
                  class="flex items-center gap-2 text-[0.8125rem] font-semibold text-primary"
                >
                  <.icon name="hero-check" class="size-4" /> {gettext("The code checks out")}
                </p>
                <p :if={@code_error} class="text-[0.8125rem] text-error">{@code_error}</p>
                <span class="flex-1"></span>
                <p class="flex items-start gap-2.5 rounded-[0.875rem] bg-base-100 p-3 text-xs leading-normal text-subtle">
                  <.icon name="hero-clock" class="mt-0.5 size-4 shrink-0" />
                  {gettext(
                    "The code changes every 30 s. If it does not match, check that the phone sets its clock automatically."
                  )}
                </p>
              </div>

              <div class={[
                "flex flex-col gap-3 rounded-[1.375rem] bg-secondary p-[1.125rem]",
                @setup.step &&
                  "border border-primary/45 shadow-[0_0_0_4px_color-mix(in_oklab,var(--color-primary)_6%,transparent)]"
              ]}>
                <div class="flex items-center gap-2.5">
                  <.step_mark n={3} state={if @setup.step, do: :current, else: :todo} />
                  <strong class="text-[0.9375rem] font-semibold">{gettext("Save the codes")}</strong>
                </div>
                <p class="text-[0.8125rem] leading-[1.45] text-subtle">
                  {gettext(
                    "If you lose the phone, each code signs in only once. They are not shown again."
                  )}
                </p>
                <%= if @setup.codes do %>
                  <ol
                    id="account-setup-codes"
                    aria-label={gettext("Recovery codes")}
                    class="grid grid-cols-2 gap-x-3 gap-y-2 rounded-[0.875rem] bg-base-100 p-3 font-mono text-[0.8125rem]"
                  >
                    <li :for={code <- @setup.codes} class="select-all">{code}</li>
                  </ol>
                  <div class="grid grid-cols-2 gap-2">
                    <button
                      type="button"
                      id="account-download-codes"
                      phx-hook=".DownloadText"
                      data-text={Enum.join(@setup.codes, "\n")}
                      data-filename="hll-conditional-actions-recovery-codes.txt"
                      class="flex h-10 items-center justify-center gap-2 rounded-full border border-line-raised bg-base-100 text-[0.8125rem]"
                    >
                      <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download")}
                    </button>
                    <button
                      type="button"
                      id="account-copy-codes"
                      phx-hook=".CopyText"
                      data-text={Enum.join(@setup.codes, "\n")}
                      class="flex h-10 items-center justify-center gap-2 rounded-full border border-line-raised bg-base-100 text-[0.8125rem]"
                    >
                      <.icon name="hero-document-duplicate" class="size-4" /> {gettext("Copy")}
                    </button>
                  </div>
                  <form id="codes-saved-form" phx-change="codes_saved">
                    <label class="flex cursor-pointer items-center gap-2.5 text-[0.8125rem]">
                      <input type="hidden" name="saved" value="false" />
                      <input
                        type="checkbox"
                        id="account-codes-saved"
                        name="saved"
                        value="true"
                        checked={@codes_saved}
                        class="settings-check"
                      />
                      {gettext("I saved them somewhere safe")}
                    </label>
                  </form>
                <% else %>
                  <p class="rounded-[0.875rem] bg-base-100 p-3 text-xs text-muted">
                    {gettext("They appear here once the code checks out.")}
                  </p>
                <% end %>
                <span class="flex-1"></span>
                <button
                  type="button"
                  id="account-activate-two-factor"
                  phx-click="activate_two_factor"
                  disabled={not (is_integer(@setup.step) and @codes_saved)}
                  class="h-12 rounded-full bg-[var(--tone-cta)] text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40"
                >
                  {gettext("Turn 2FA on")}
                </button>
              </div>
            </div>

            <%!-- ── On ─────────────────────────────────────────────────── --%>
            <div
              :if={@two_factor == :on and is_nil(@pending_action)}
              class="flex flex-wrap items-center gap-3 rounded-2xl bg-secondary px-4 py-3.5"
            >
              <.icon name="hero-key" class="size-4 shrink-0 text-muted" />
              <span class="min-w-0 flex-1 text-[0.8125rem]">
                {ngettext(
                  "%{count} recovery code left.",
                  "%{count} recovery codes left.",
                  TwoFactor.recovery_codes_left(@current_user),
                  count: TwoFactor.recovery_codes_left(@current_user)
                )}
              </span>
              <%!-- No `data-confirm` on either: the code prompt that
                    follows is the confirmation, and a better one — it asks
                    for something only the owner has. --%>
              <button
                type="button"
                phx-click="ask_regenerate"
                class="flex h-10 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 text-[0.8125rem]"
              >
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("New recovery codes")}
              </button>
              <button
                type="button"
                phx-click="ask_disable"
                class="flex h-10 items-center gap-2 rounded-full px-4 text-[0.8125rem] text-error hover:bg-error/8"
              >
                <.icon name="hero-lock-open" class="size-4" /> {gettext("Turn off")}
              </button>
            </div>

            <%!-- ── Confirming a change with a code ─────────────────────── --%>
            <div
              :if={@pending_action}
              class={[
                "flex flex-col gap-4 rounded-[1.375rem] border p-5",
                if(@pending_action == :disable,
                  do: "border-error/30 bg-error/6",
                  else: "border-base-300 bg-secondary"
                )
              ]}
            >
              <p class="text-sm">
                <%= if @pending_action == :disable do %>
                  {gettext(
                    "Turning two factor off leaves your password as the only thing between somebody and this account."
                  )}
                <% else %>
                  {gettext("New recovery codes replace the ones you have now, which stop working.")}
                <% end %>
              </p>

              <p class="text-[0.8125rem] text-subtle">
                {gettext("Type a code from your app to confirm it is you. A recovery code works too.")}
              </p>

              <p :if={@step_up_error} class="text-[0.8125rem] text-error">{@step_up_error}</p>

              <form
                id="step-up-form"
                phx-submit="confirm_step_up"
                class="settings-form flex flex-wrap items-end gap-3"
              >
                <div class="w-full sm:w-56">
                  <.input
                    type="text"
                    id="step_up_code"
                    name="code"
                    value=""
                    label={gettext("Code from your app")}
                    placeholder="123456"
                    inputmode="numeric"
                    autocomplete="one-time-code"
                    class="text-center font-mono text-lg tracking-[0.3em]"
                    no_margin
                    required
                  />
                </div>

                <button
                  type="submit"
                  class={[
                    "h-[2.875rem] rounded-full px-5 text-sm font-semibold",
                    if(@pending_action == :disable,
                      do: "bg-error text-error-content",
                      else: "bg-[var(--tone-cta)] text-[var(--tone-on-cta)]"
                    )
                  ]}
                >
                  {if @pending_action == :disable,
                    do: gettext("Turn two factor off"),
                    else: gettext("Make new codes")}
                </button>

                <button
                  type="button"
                  phx-click="cancel_step_up"
                  class="h-[2.875rem] rounded-full px-4 text-sm text-subtle hover:text-base-content"
                >
                  {gettext("Cancel")}
                </button>
              </form>
            </div>

            <%!-- ── New codes after "Novos códigos", shown once ─────────── --%>
            <div
              :if={@fresh_recovery_codes}
              id="account-recovery-codes"
              class="flex flex-col gap-3 rounded-[1.375rem] border border-warning/40 bg-warning/10 p-5"
            >
              <p class="flex items-center gap-2 text-sm font-semibold">
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
                {gettext("Write these down now")}
              </p>
              <p class="text-[0.8125rem] text-subtle">
                {gettext(
                  "Each one signs you in once if you lose your phone. They are not shown again."
                )}
              </p>
              <ol class="grid grid-cols-2 gap-x-6 gap-y-1.5 rounded-2xl bg-base-100 p-4 font-mono text-[0.8125rem] sm:grid-cols-3">
                <li :for={code <- @fresh_recovery_codes} class="select-all">{code}</li>
              </ol>
              <button
                type="button"
                phx-click="dismiss_recovery_codes"
                class="h-10 w-fit rounded-full border border-base-300 bg-base-100 px-4 text-[0.8125rem]"
              >
                {gettext("I have written them down")}
              </button>
            </div>
          </section>

          <%!-- ── Password ────────────────────────────────────────────── --%>
          <section
            id="account-password"
            aria-label={gettext("Change password")}
            class="flex flex-col gap-3.5 rounded-panel bg-base-100 px-6 py-[1.375rem]"
          >
            <div class="flex flex-wrap items-baseline gap-2.5">
              <h2 class="font-display text-lg font-semibold">{gettext("Change password")}</h2>
              <span class="text-xs text-muted">
                {gettext("Changing it ends the other sessions. At least %{count} characters.",
                  count: PasswordPolicy.min_length()
                )}
              </span>
            </div>
            <.form
              for={@password_form}
              id="password-change-form"
              phx-change="validate_password"
              phx-submit="change_password"
              class="settings-form grid items-start gap-3 md:grid-cols-[repeat(3,minmax(0,1fr))_auto]"
            >
              <.input
                field={@password_form[:current_password]}
                type="password"
                label={gettext("Current password")}
                autocomplete="current-password"
                no_margin
                required
              />
              <.input
                field={@password_form[:password]}
                type="password"
                label={gettext("New password")}
                autocomplete="new-password"
                no_margin
                required
              />
              <.input
                field={@password_form[:password_confirmation]}
                type="password"
                label={gettext("Repeat the new one")}
                autocomplete="new-password"
                no_margin
                required
              />
              <button
                type="submit"
                id="password-change-submit"
                phx-disable-with={gettext("Saving...")}
                class="h-[2.875rem] self-start whitespace-nowrap rounded-full border border-base-300 bg-secondary px-[1.125rem] text-sm transition-colors hover:bg-base-300 md:mt-[1.625rem]"
              >
                {gettext("Change password")}
              </button>
            </.form>
          </section>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const text = this.el.dataset.text || ""
              if (navigator.clipboard) navigator.clipboard.writeText(text)
              this.el.classList.add("text-primary")
              setTimeout(() => this.el.classList.remove("text-primary"), 1200)
            })
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadText">
        export default {
          mounted() {
            this.el.addEventListener("click", () => {
              const blob = new Blob([(this.el.dataset.text || "") + "\n"], {type: "text/plain"})
              const url = URL.createObjectURL(blob)
              const a = document.createElement("a")
              a.href = url
              a.download = this.el.dataset.filename || "codes.txt"
              document.body.appendChild(a)
              a.click()
              a.remove()
              setTimeout(() => URL.revokeObjectURL(url), 1000)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :n, :integer, required: true
  attr :state, :atom, values: [:done, :current, :todo], required: true

  defp step_mark(assigns) do
    ~H"""
    <span class={[
      "flex size-[1.625rem] shrink-0 items-center justify-center rounded-full font-mono text-xs font-semibold",
      case @state do
        :done -> "bg-primary text-primary-content"
        :current -> "border-[1.5px] border-primary text-primary"
        :todo -> "border-[1.5px] border-line-strong text-muted"
      end
    ]}>
      <.icon :if={@state == :done} name="hero-check" class="size-3.5" />
      <span :if={@state != :done}>{@n}</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :ok, :boolean, default: false

  # Six boxes that behave like one field: typing moves on, backspace moves
  # back, a pasted code fills them all, and the sixth digit submits. The
  # value travels in the hidden `code` input.
  defp digit_boxes(assigns) do
    ~H"""
    <div class={["settings-digits", @ok && "settings-digits--ok"]}>
      <fieldset id={@id} phx-hook=".DigitBoxes" phx-update="ignore" class="m-0 border-0 p-0">
        <legend class="sr-only">{gettext("6 digit code")}</legend>
        <input type="hidden" name="code" value="" data-code />
        <div class="grid grid-cols-6 gap-1.5">
          <input
            :for={n <- 1..6}
            type="text"
            inputmode="numeric"
            autocomplete={if n == 1, do: "one-time-code", else: "off"}
            maxlength="1"
            aria-label={gettext("Digit %{n}", n: n)}
            data-digit
            class="h-[3.25rem] w-full rounded-xl border border-line-raised bg-base-100 p-0 text-center font-mono text-[1.375rem] outline-none focus:border-primary/60"
          />
        </div>
      </fieldset>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DigitBoxes">
      export default {
        mounted() {
          const boxes = [...this.el.querySelectorAll("[data-digit]")]
          const hidden = this.el.querySelector("[data-code]")
          const sync = () => {
            hidden.value = boxes.map((b) => b.value).join("")
            if (hidden.value.length === 6) this.el.closest("form").requestSubmit()
          }
          const fill = (from, text) => {
            const digits = text.replace(/\D/g, "").slice(0, 6 - from).split("")
            digits.forEach((d, i) => (boxes[from + i].value = d))
            const next = Math.min(from + digits.length, 5)
            boxes[next].focus()
            sync()
          }
          boxes.forEach((box, i) => {
            box.addEventListener("input", () => {
              const v = box.value.replace(/\D/g, "")
              if (v.length > 1) return fill(i, v)
              box.value = v
              if (v && i < 5) boxes[i + 1].focus()
              sync()
            })
            box.addEventListener("keydown", (e) => {
              if (e.key === "Backspace" && !box.value && i > 0) boxes[i - 1].focus()
            })
            box.addEventListener("paste", (e) => {
              e.preventDefault()
              fill(i, (e.clipboardData || window.clipboardData).getData("text"))
            })
          })
        },
        updated() {}
      }
    </script>
    """
  end
end
