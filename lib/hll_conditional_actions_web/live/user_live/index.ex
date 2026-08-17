defmodule HllConditionalActionsWeb.UserLive.Index do
  @moduledoc """
  User administration: who can sign in, with which role, and on which servers.

  The role decides *what* an account may do; the server list decides *where*.
  Assigning no servers means every server, which keeps a single-community
  install from having to configure anything.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_users}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Servers

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Users"))
     |> assign(:servers, Servers.list_servers())
     |> assign(:selected_servers, [])
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:user, nil) |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    user = %User{servers: []}

    socket
    |> assign(:user, user)
    |> assign(:selected_servers, [])
    |> assign_form(Accounts.change_user(user))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)

    socket
    |> assign(:user, user)
    |> assign(:selected_servers, Enum.map(user.servers, &to_string(&1.id)))
    |> assign_form(Accounts.change_user(user))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_user(socket.assigns.user, params)

    {:noreply,
     socket
     |> assign(:selected_servers, server_ids(params))
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    save_user(socket, socket.assigns.user, params)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    cond do
      to_string(user.id) == to_string(socket.assigns.current_user.id) ->
        {:noreply, put_flash(socket, :error, gettext("You cannot deactivate your own account."))}

      user.active and Accounts.last_administrator?(user) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This is the last account that can manage users.")
         )}

      true ->
        {:ok, _user} = Accounts.update_user(user, %{active: not user.active})
        {:noreply, load(socket)}
    end
  end

  # The escape hatch for a phone that is gone and recovery codes that went with
  # it. Deliberately available to anybody who can manage users, and deliberately
  # loud in the confirmation: it drops an account back to a password alone.
  def handle_event("clear_two_factor", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:ok, _user} = TwoFactor.disable(user)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Two factor switched off for %{username}.", username: user.username)
     )
     |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    if to_string(user.id) == to_string(socket.assigns.current_user.id) do
      {:noreply, put_flash(socket, :error, gettext("You cannot remove your own account."))}
    else
      case Accounts.delete_user(user) do
        {:ok, _user} ->
          {:noreply, socket |> put_flash(:info, gettext("User removed.")) |> load()}

        {:error, :last_administrator} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("This is the last account that can manage users.")
           )}
      end
    end
  end

  # Checkbox groups drop the key entirely when nothing is ticked.
  defp server_ids(params), do: Map.get(params, "server_ids", [])

  defp save_user(socket, %User{id: nil}, params) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        {:ok, _user} = Accounts.set_user_servers(user, server_ids(params))

        {:noreply,
         socket |> put_flash(:info, gettext("User created.")) |> push_navigate(to: ~p"/users")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_user(socket, user, params) do
    # Leaving the password blank keeps the current one.
    params =
      if String.trim(params["password"] || "") == "",
        do: Map.drop(params, ["password", "password_confirmation"]),
        else: params

    case Accounts.update_user(user, params) do
      {:ok, updated} ->
        {:ok, _user} = Accounts.set_user_servers(updated, server_ids(params))

        {:noreply,
         socket |> put_flash(:info, gettext("User updated.")) |> push_navigate(to: ~p"/users")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp load(socket) do
    socket
    |> assign(:users, Accounts.list_users())
    |> assign(:two_factor_ids, TwoFactor.enabled_user_ids())
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("Users")}
      page_subtitle={gettext("Who can sign in, and which servers they administer")}
    >
      <:actions>
        <.button
          link_type="live_patch"
          to={~p"/users/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New user")}
        />
      </:actions>

      <.card padded={false}>
        <.data_table id="users" rows={@users}>
          <:col :let={user} label={gettext("User")}>
            <div class="flex flex-wrap items-center gap-1.5">
              <span class="font-medium">{user.username}</span>
              <.tone_badge :if={not user.active} tone="ghost" size="xs">
                {gettext("Inactive")}
              </.tone_badge>

              <.tone_badge :if={user.must_change_password?} tone="warning" size="xs">
                {gettext("Must change password")}
              </.tone_badge>

              <.tone_badge
                :if={MapSet.member?(@two_factor_ids, user.id)}
                tone="success"
                size="xs"
                icon="hero-lock-closed"
              >
                {gettext("2FA")}
              </.tone_badge>
            </div>

            <p class="text-xs text-muted">{user.name || user.email}</p>
          </:col>

          <:col :let={user} label={gettext("Role")}>
            <.tone_badge tone="ghost">{user.role && user.role.name}</.tone_badge>
          </:col>

          <:col :let={user} label={gettext("Servers")}>
            <span :if={user.servers == []} class="text-sm text-muted">
              {gettext("Every server")}
            </span>

            <span :if={user.servers != []} class="text-sm">
              {Enum.map_join(user.servers, ", ", & &1.name)}
            </span>
          </:col>

          <:col :let={user} label={gettext("Last sign in")}>
            <%= if user.last_login_at do %>
              <.local_time
                id={"user-#{user.id}-login"}
                at={user.last_login_at}
                class="text-sm text-subtle"
              />
            <% else %>
              <span class="text-sm text-muted">{gettext("never")}</span>
            <% end %>
          </:col>

          <:action :let={user}>
            <.button
              link_type="live_patch"
              to={~p"/users/#{user}/edit"}
              size="xs"
              variant="ghost"
              color="gray"
              label={gettext("Edit")}
            />

            <.row_menu id={"user-menu-#{user.id}"}>
              <.menu_item icon="hero-power" phx-click="toggle_active" phx-value-id={user.id}>
                {if user.active, do: gettext("Deactivate"), else: gettext("Activate")}
              </.menu_item>

              <.menu_item
                :if={MapSet.member?(@two_factor_ids, user.id)}
                icon="hero-lock-open"
                phx-click="clear_two_factor"
                phx-value-id={user.id}
                data-confirm={
                  gettext(
                    "Switch two factor off for %{username}? Their password alone will be enough to sign in, until they set it up again.",
                    username: user.username
                  )
                }
              >
                {gettext("Switch two factor off")}
              </.menu_item>

              <.menu_item
                tone="error"
                icon="hero-trash"
                phx-click="delete"
                phx-value-id={user.id}
                data-confirm={gettext("Remove %{username}?", username: user.username)}
              >
                {gettext("Remove")}
              </.menu_item>
            </.row_menu>
          </:action>
        </.data_table>
      </.card>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="user-modal"
        title={if @user.id, do: gettext("Edit user"), else: gettext("New user")}
        on_cancel={JS.patch(~p"/users")}
      >
        <.form
          for={@form}
          id="user-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-3"
        >
          <.input field={@form[:username]} type="text" label={gettext("Username")} required />
          <.input field={@form[:name]} type="text" label={gettext("Full name")} />
          <.input field={@form[:email]} type="email" label={gettext("Email")} />
          <.input
            field={@form[:role_id]}
            type="select"
            label={gettext("Role")}
            options={Accounts.role_options()}
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="new-password"
            placeholder={if @user.id, do: gettext("Leave blank to keep the current password")}
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            autocomplete="new-password"
          />
          <div :if={@servers != []} class="rounded-box bg-base-200 p-3">
            <p class="mb-1 text-sm font-medium">{gettext("Servers")}</p>

            <p class="mb-2 text-xs text-muted">
              {gettext("Leave all unticked to give this account every server.")}
            </p>

            <label
              :for={server <- @servers}
              class="flex cursor-pointer items-center gap-2 py-1"
            >
              <input
                type="checkbox"
                name="user[server_ids][]"
                value={server.id}
                checked={to_string(server.id) in @selected_servers}
                class="pc-checkbox"
              /> <span class="text-sm">{server.name}</span>
              <.tone_badge tone="ghost" size="xs">{Labels.game(server.game)}</.tone_badge>
            </label>
          </div>

          <.input
            field={@form[:must_change_password?]}
            type="checkbox"
            label={gettext("Require a password change on next sign in")}
          /> <.input field={@form[:active]} type="checkbox" label={gettext("Active")} />
          <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
            <.button
              link_type="live_patch"
              to={~p"/users"}
              size="sm"
              variant="ghost"
              color="gray"
              label={gettext("Cancel")}
            />
            <.button
              type="submit"
              size="sm"
              color="primary"
              phx-disable-with={gettext("Saving...")}
              label={gettext("Save")}
            />
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
