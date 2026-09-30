defmodule HllConditionalActionsWeb.ResetPasswordLive do
  @moduledoc """
  The new-password form of a reset link, embedded in the `/login` page
  (`SessionController`, `mode: :reset`).

  It exists only to tick the `PasswordPolicy` checklist and fill the
  strength meter as the password is typed. The form is a plain POST to
  `/login` (`reset_password` params), where the controller checks the link
  again and saves - so the password is set by the same code with or without
  a live connection.

  Not mounted by the router, which is why it skips the shell's `Nav` hook
  (that one attaches to `handle_params`, which only routed views have).
  """

  use Phoenix.LiveView
  use Gettext, backend: HllConditionalActionsWeb.Gettext
  use HllConditionalActionsWeb, :verified_routes

  alias HllConditionalActions.Accounts.PasswordReset
  alias HllConditionalActionsWeb.AuthLayout

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    token = session["token"]

    # Not routed, so the locale hook of the live_session does not run here:
    # the page hands its language over instead.
    case session["locale"] do
      locale when is_binary(locale) ->
        Gettext.put_locale(HllConditionalActionsWeb.Gettext, locale)

      _none ->
        :ok
    end

    username =
      case PasswordReset.verify(token) do
        {:ok, user} -> user.username
        :error -> nil
      end

    {:ok,
     assign(socket,
       token: token,
       username: username,
       typed: %{},
       errors: session["errors"] || []
     ), layout: false}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"reset_password" => params}, socket) do
    {:noreply, assign(socket, typed: params, errors: [])}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:reset_password}
      id="reset-password-form"
      action={~p"/login"}
      method="post"
      phx-change="validate"
      class="auth-form"
    >
      <input type="hidden" name="reset_password[token]" value={@token} />
      <AuthLayout.new_password_fields
        id="reset"
        name="reset_password"
        typed={@typed}
        username={@username}
        errors={@errors}
      />
      <button type="submit" id="reset-password-submit" class="auth-cta">
        {gettext("Save the new password")} <AuthLayout.arrow />
      </button>
    </.form>
    """
  end
end
