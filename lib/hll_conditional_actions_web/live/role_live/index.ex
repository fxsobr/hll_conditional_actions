defmodule HllConditionalActionsWeb.RoleLive.Index do
  @moduledoc """
  Role administration: which permissions each role grants.

  The three built-in roles can be edited but not deleted, and a role that is
  still assigned to somebody cannot be removed either.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_roles}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Role

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Roles")) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:role, nil) |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    role = %Role{}
    socket |> assign(:role, role) |> assign_form(Accounts.change_role(role))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    role = Accounts.get_role!(id)
    socket |> assign(:role, role) |> assign_form(Accounts.change_role(role))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"role" => params}, socket) do
    changeset = Accounts.change_role(socket.assigns.role, normalize(params))
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"role" => params}, socket) do
    save_role(socket, socket.assigns.role, normalize(params))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    role = Accounts.get_role!(id)

    case Accounts.delete_role(role) do
      {:ok, _role} ->
        {:noreply, socket |> put_flash(:info, gettext("Role removed.")) |> load()}

      {:error, :system_role} ->
        {:noreply, put_flash(socket, :error, gettext("Built-in roles cannot be removed."))}

      {:error, :role_in_use} ->
        {:noreply, put_flash(socket, :error, gettext("Move its users to another role first."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove that role."))}
    end
  end

  defp save_role(socket, %Role{id: nil}, params) do
    case Accounts.create_role(params) do
      {:ok, _role} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Role created.")) |> push_navigate(to: ~p"/roles")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_role(socket, role, params) do
    case Accounts.update_role(role, params) do
      {:ok, _role} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Role updated.")) |> push_navigate(to: ~p"/roles")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # Checkbox groups post "false" for every unchecked box alongside the checked
  # values; the schema drops anything that is not a real permission name.
  defp normalize(params) do
    Map.update(params, "permissions", [], fn
      permissions when is_list(permissions) -> Enum.reject(permissions, &(&1 in ["false", ""]))
      _other -> []
    end)
  end

  defp load(socket) do
    roles = Accounts.list_roles()

    socket
    |> assign(:roles, roles)
    |> assign(:usage, Map.new(roles, &{&1.id, Accounts.users_with_role(&1.id)}))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp checked?(form, permission) do
    to_string(permission) in (Phoenix.HTML.Form.input_value(form, :permissions) || [])
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("Roles")}
      page_subtitle={gettext("What each kind of account is allowed to do")}
    >
      <:actions>
        <.button
          link_type="live_patch"
          to={~p"/roles/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New role")}
        />
      </:actions>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <div :for={role <- @roles} class="rounded-box border border-base-300 bg-base-100">
          <div class="flex h-full flex-col gap-3 p-4 sm:p-5">
            <div class="flex items-start justify-between gap-2">
              <div class="flex min-w-0 items-center gap-2.5">
                <div class="flex size-9 shrink-0 items-center justify-center rounded-box bg-base-200 text-subtle">
                  <.icon name="hero-shield-check" class="size-4" />
                </div>

                <div class="min-w-0">
                  <h2 class="truncate font-semibold leading-tight">{role.name}</h2>

                  <p class="text-xs text-muted">
                    {ngettext("%{count} user", "%{count} users", @usage[role.id],
                      count: @usage[role.id]
                    )}
                  </p>
                </div>
              </div>

              <.tone_badge :if={role.system?} tone="ghost">{gettext("Built-in")}</.tone_badge>
            </div>

            <p :if={role.description} class="text-sm text-subtle">{role.description}</p>

            <ul class="space-y-1 text-sm">
              <li
                :for={permission <- role.permissions}
                class="flex items-start gap-1.5 text-base-content/80"
              >
                <.icon name="hero-check" class="mt-0.5 size-3.5 shrink-0 text-success" />
                {permission_label(permission)}
              </li>
            </ul>

            <div class="mt-auto flex items-center justify-end gap-1 pt-2">
              <.button
                link_type="live_patch"
                to={~p"/roles/#{role}/edit"}
                size="xs"
                variant="ghost"
                color="gray"
                label={gettext("Edit")}
              />
              <.button
                :if={not role.system?}
                type="button"
                size="xs"
                variant="ghost"
                color="danger"
                phx-click="delete"
                phx-value-id={role.id}
                data-confirm={gettext("Remove the role \"%{name}\"?", name: role.name)}
                label={gettext("Remove")}
              />
            </div>
          </div>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="role-modal"
        title={if @role.id, do: gettext("Edit role"), else: gettext("New role")}
        on_cancel={JS.patch(~p"/roles")}
        class="max-w-2xl"
      >
        <.form
          for={@form}
          id="role-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input field={@form[:name]} type="text" label={gettext("Name")} required />
          <.input
            field={@form[:description]}
            type="textarea"
            label={gettext("Description")}
            rows="2"
          />
          <div class="space-y-3">
            <p class="text-sm font-medium">{gettext("Permissions")}</p>

            <div
              :for={{group, permissions} <- Labels.permission_groups()}
              class="rounded-box bg-base-200 p-3"
            >
              <p class="mb-2 text-xs font-semibold uppercase tracking-wide opacity-60">{group}</p>

              <label
                :for={{permission, label} <- permissions}
                class="flex cursor-pointer items-center gap-2 py-1"
              >
                <input
                  type="checkbox"
                  name="role[permissions][]"
                  value={permission}
                  checked={checked?(@form, permission)}
                  class="pc-checkbox"
                /> <span class="text-sm">{label}</span>
              </label>
            </div>

            <p class="text-xs text-muted">
              {gettext("A \"manage\" permission already includes the matching \"view\" one.")}
            </p>
          </div>

          <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
            <.button
              link_type="live_patch"
              to={~p"/roles"}
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

  # The translated sentence for a permission; the raw atom never reaches the
  # screen. Custom roles may hold values Labels does not know — show them as
  # they are rather than crashing the page.
  defp permission_label(permission) when is_binary(permission) do
    permission_label(String.to_existing_atom(permission))
  rescue
    ArgumentError -> permission
    FunctionClauseError -> permission
  end

  defp permission_label(permission) when is_atom(permission) do
    Labels.permission(permission)
  rescue
    FunctionClauseError -> to_string(permission)
  end
end
