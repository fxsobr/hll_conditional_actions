defmodule HllConditionalActionsWeb.AccountLive.Password do
  @moduledoc """
  Choosing a password of your own, then (optionally) the authenticator app.

  Reachable while `must_change_password?` is set - the state the bootstrap
  `admin` account starts in and where every other page redirects here - and
  by anyone signed in who wants a new password.

  Two steps, as on the "Troque a senha padrão" board:

    1. **Senha nova** - the new password, with a strength meter and the
       `PasswordPolicy` checklist ticked off as it is typed. Saving signs
       every other session of the account out.
    2. **App autenticador** - scan the QR code (or type the key), confirm
       with a code, keep the recovery codes. Two factor is optional in this
       app, so the step can be skipped; an account that already has it goes
       straight to the dashboard after step 1.
  """

  use HllConditionalActionsWeb, :live_view

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Enrolments
  alias HllConditionalActions.Accounts.OwnPassword
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActionsWeb.AuthLayout

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Change password"))
     |> assign(:session_id, Sessions.id_for(session["session_token"]))
     |> assign(:default_password?, default_password?(user))
     |> assign(:forced?, user.must_change_password?)
     |> assign(:two_factor?, TwoFactor.enabled?(user))
     |> assign(:step, :password)
     |> assign(:typed, %{})
     |> assign(:errors, [])
     |> assign(:code_error, nil)
     |> assign(:form, to_form(%{}, as: :user))}
  end

  # The bootstrap account still on the password every install ships with.
  # Checked once, on mount: it costs a password hash.
  defp default_password?(%User{} = user) do
    %{username: username, password: password} = Accounts.bootstrap_credentials()

    user.username == username and user.must_change_password? and
      User.valid_password?(user, password)
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     socket
     |> assign(:typed, params)
     |> assign(:errors, [])
     |> assign(:form, to_form(params, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    case OwnPassword.update(user, params,
           current: false,
           keep_session_id: socket.assigns.session_id
         ) do
      {:ok, user, _revoked} ->
        socket = assign(socket, current_user: user, forced?: false, default_password?: false)

        if TwoFactor.enabled?(user) do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Password changed."))
           |> push_navigate(to: ~p"/")}
        else
          {:noreply, start_authenticator(socket, user)}
        end

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:typed, params)
         |> assign(:errors, password_errors(changeset))
         |> assign(:form, to_form(params, as: :user))}
    end
  end

  def handle_event("confirm_2fa", %{"code" => code}, socket) do
    user = socket.assigns.current_user

    case TwoFactor.confirm(user, socket.assigns.secret, String.trim(code)) do
      {:ok, user, recovery_codes} ->
        :ok = Enrolments.clear(user)

        {:noreply,
         socket
         |> assign(current_user: user, step: :recovery, recovery_codes: recovery_codes)
         |> assign(:two_factor?, true)}

      {:error, :invalid_code} ->
        {:noreply,
         socket
         |> assign(:code_error, gettext("That code is not right. Check your app and try again."))
         # A new id remounts the boxes empty, so the next try starts clean.
         |> update(:attempt, &(&1 + 1))}
    end
  end

  defp start_authenticator(socket, user) do
    enrolment = Enrolments.start(user)

    socket
    |> assign(:step, :authenticator)
    |> assign(:secret, enrolment.secret)
    |> assign(:setup, Enrolments.display(user, enrolment.secret))
    |> assign(:attempt, 0)
    |> assign(:code_error, nil)
    |> put_flash(:info, gettext("Password changed."))
  end

  defp password_errors(changeset) do
    changeset.errors
    |> Keyword.take([:password, :password_confirmation])
    |> Enum.map(fn {_field, error} -> translate_error(error) end)
  end

  defp steps(step) do
    [
      {gettext("Fresh password"), if(step == :password, do: :current, else: :done)},
      {gettext("Authenticator app"), if(step == :password, do: :todo, else: :current)}
    ]
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <AuthLayout.shell
      flash={@flash}
      art={:password}
      return_to={~p"/account/password"}
      lede={
        if(@default_password?,
          do:
            gettext(
              "The install has just been born. In two steps the administrator account is protected."
            )
        )
      }
    >
      <:top>
        <AuthLayout.top_pill :if={@forced? or @step != :password} id="signed-in-as">
          <AuthLayout.around
            text={gettext("Signing in as %{username}", username: AuthLayout.hole())}
            class="font-mono text-base-content"
            value={@current_user.username}
          />
        </AuthLayout.top_pill>
        <AuthLayout.top_pill
          :if={not @forced? and @step == :password}
          href={~p"/account"}
          id="back-to-account"
        >
          {gettext("Back to my account")}
        </AuthLayout.top_pill>
      </:top>

      <%= case @step do %>
        <% :password -> %>
          <.password_step {assigns} />
        <% :authenticator -> %>
          <.authenticator_step {assigns} />
        <% :recovery -> %>
          <.recovery_step {assigns} />
      <% end %>
    </AuthLayout.shell>
    """
  end

  defp password_step(assigns) do
    ~H"""
    <div class="auth-stack auth-stack--tight">
      <div class="auth-head">
        <AuthLayout.stepper :if={not @two_factor?} id="password-steps" steps={steps(:password)} />
        <h1 class="auth-title auth-title--step">
          {if @default_password?,
            do: gettext("Change the default password"),
            else: gettext("Change password")}
        </h1>
      </div>

      <AuthLayout.note
        :if={@default_password?}
        id="default-password-warning"
        tone={:warning}
        icon={:warning}
      >
        <AuthLayout.around
          text={
            gettext(
              "You signed in with %{credentials}, the password every install comes with. Anybody can try it. Choose a new one to continue.",
              credentials: AuthLayout.hole()
            )
          }
          class="font-mono"
          value="admin / admin"
        />
      </AuthLayout.note>

      <AuthLayout.note
        :if={@forced? and not @default_password?}
        id="password-required"
        tone={:warning}
        icon={:warning}
      >
        {gettext("Choose a password of your own before using the platform.")}
      </AuthLayout.note>

      <.form
        for={@form}
        id="password-form"
        phx-change="validate"
        phx-submit="save"
        class="auth-form"
      >
        <AuthLayout.new_password_fields
          id="password"
          name="user"
          typed={@typed}
          username={@current_user.username}
          errors={@errors}
        />

        <button
          type="submit"
          id="password-submit"
          class="auth-cta auth-cta--step"
          phx-disable-with={gettext("Saving...")}
        >
          {if @two_factor?, do: gettext("Save password"), else: gettext("Save and continue")}
          <AuthLayout.arrow />
        </button>
        <p :if={not @two_factor?} class="auth-after">
          {gettext("Next you turn on the authenticator app.")}
        </p>
      </.form>
    </div>
    """
  end

  defp authenticator_step(assigns) do
    ~H"""
    <div class="auth-stack auth-stack--tight">
      <div class="auth-head">
        <AuthLayout.stepper id="password-steps" steps={steps(:authenticator)} />
        <h1 class="auth-title auth-title--step">{gettext("Turn on the authenticator app")}</h1>
        <p class="auth-sub">
          {gettext(
            "Scan the code with an authenticator app and type the 6 digits it shows. Optional, but it keeps the account safe even if the password leaks."
          )}
        </p>
      </div>

      <div id="authenticator-setup" class="auth-setup">
        <div class="auth-qr" role="img" aria-label={gettext("QR code for the authenticator app")}>
          {Phoenix.HTML.raw(@setup.qr_svg)}
        </div>
        <div class="flex min-w-0 flex-col gap-2">
          <span class="auth-label">{gettext("Or type the key")}</span>
          <code id="authenticator-key" class="auth-key">{@setup.readable}</code>
          <span class="text-xs text-muted">{gettext("Account: %{name}", name: @current_user.username)}</span>
        </div>
      </div>

      <AuthLayout.note
        :if={@code_error}
        id="authenticator-error"
        tone={:error}
        icon={:error}
        role="alert"
      >
        {@code_error}
      </AuthLayout.note>

      <.form for={%{}} id="authenticator-form" phx-submit="confirm_2fa" class="auth-form">
        <AuthLayout.code_boxes
          id={"authenticator-digits-#{@attempt}"}
          input_id="authenticator-code"
          autosubmit
          invalid={@code_error != nil}
        />
        <button type="submit" id="authenticator-submit" class="auth-cta auth-cta--step">
          {gettext("Turn on and continue")} <AuthLayout.arrow />
        </button>
        <.link navigate={~p"/"} id="authenticator-skip" class="auth-link auth-link--center">
          {gettext("Not now")}
        </.link>
      </.form>
    </div>
    """
  end

  defp recovery_step(assigns) do
    ~H"""
    <div class="auth-stack auth-stack--tight">
      <div class="auth-head">
        <AuthLayout.stepper
          id="password-steps"
          steps={[{gettext("Fresh password"), :done}, {gettext("Authenticator app"), :done}]}
        />
        <h1 class="auth-title auth-title--step">{gettext("Keep the recovery codes")}</h1>
        <p class="auth-sub">
          {gettext(
            "Each one signs you in once if you lose your phone. They are not shown again: save them somewhere safe."
          )}
        </p>
      </div>

      <ul id="recovery-codes" class="auth-recovery">
        <li :for={code <- @recovery_codes} class="font-mono">{code}</li>
      </ul>

      <.link navigate={~p"/"} id="recovery-done" class="auth-cta auth-cta--step">
        {gettext("Saved them, continue")} <AuthLayout.arrow />
      </.link>
    </div>
    """
  end
end
