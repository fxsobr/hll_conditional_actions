defmodule HllConditionalActionsWeb.AccountLive.Password do
  @moduledoc """
  Lets the signed in user set a new password.

  Reachable while `must_change_password?` is set, which is the state the
  bootstrap `admin` account starts in and where every other page redirects
  here.
  """

  use HllConditionalActionsWeb, :live_view

  alias HllConditionalActions.Accounts

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Change password"))
     |> assign_form(Accounts.change_password(socket.assigns.current_user))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_password(socket.assigns.current_user, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.update_password(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, gettext("Password changed."))
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :user))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} return_to={~p"/account/password"}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">{gettext("Change password")}</h1>

          <p class="mt-1 text-sm text-muted">
            {gettext("Pick something only you know. At least 8 characters.")}
          </p>
        </div>

        <.alert
          :if={@current_user.must_change_password?}
          color="warning"
          variant="soft"
          with_icon
          label={gettext("Choose a password of your own before using the platform.")}
        />

        <.form
          for={@form}
          id="password-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm the new password")}
            autocomplete="new-password"
            required
          />

          <.button
            type="submit"
            color="primary"
            icon="hero-check"
            class="w-full"
            phx-disable-with={gettext("Saving...")}
            label={gettext("Save password")}
          />
        </.form>

        <.link
          :if={not @current_user.must_change_password?}
          navigate={~p"/account"}
          class="block text-center text-sm text-subtle underline-offset-2 hover:text-primary hover:underline"
        >
          {gettext("Back to my account")}
        </.link>
      </div>
    </Layouts.auth>
    """
  end
end
