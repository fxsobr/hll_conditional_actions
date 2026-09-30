defmodule HllConditionalActionsWeb.RoleLive.Index do
  @moduledoc """
  Role administration (the Roles board): the roles on the left, the one
  picked on the right as a sheet of "Ver" and "Gerenciar" switches, one row
  per thing a role can touch.

  Built-in roles do not change: their sheet is read-only, and "Duplicar"
  makes an editable copy. A custom role can be edited and, once nobody holds
  it, removed. Opening `/roles` shows the first role.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_roles}}

  import HllConditionalActionsWeb.SettingsComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.Role

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Roles")) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # The board always has a role open: the first custom one, else the first.
  defp apply_action(socket, :index, _params) do
    case Enum.find(socket.assigns.roles, &(not &1.system?)) || List.first(socket.assigns.roles) do
      nil -> socket |> assign(:role, nil) |> assign(:form, nil)
      role -> socket |> assign(:role, role) |> assign_form(Accounts.change_role(role))
    end
  end

  defp apply_action(socket, :new, _params) do
    role = %Role{permissions: []}
    socket |> assign(:role, role) |> assign_form(Accounts.change_role(role))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    role = Accounts.get_role!(id)
    socket |> assign(:role, role) |> assign_form(Accounts.change_role(role))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"role" => params}, socket) do
    if editable?(socket.assigns.role) do
      changeset = Accounts.change_role(socket.assigns.role, normalize(params))
      {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"role" => params}, socket) do
    if editable?(socket.assigns.role) do
      save_role(socket, socket.assigns.role, normalize(params))
    else
      {:noreply,
       put_flash(socket, :error, gettext("Built-in roles do not change. Duplicate it instead."))}
    end
  end

  def handle_event("duplicate", _params, socket) do
    role = socket.assigns.role

    attrs = %{
      "name" => copy_name(role_label(role), socket.assigns.roles),
      "description" => role.description,
      "permissions" => Enum.map(role.permissions, &to_string/1)
    }

    case Accounts.create_role(attrs) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Copy created. Adjust it and save."))
         |> load()
         |> push_patch(to: ~p"/roles/#{copy}/edit")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not duplicate that role."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    role = Accounts.get_role!(id)

    case Accounts.delete_role(role) do
      {:ok, _role} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role removed."))
         |> load()
         |> push_patch(to: ~p"/roles")}

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
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role created."))
         |> load()
         |> push_patch(to: ~p"/roles/#{role}/edit")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_role(socket, role, params) do
    case Accounts.update_role(role, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role updated."))
         |> load()
         |> assign(:role, updated)
         |> assign_form(Accounts.change_role(updated))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp editable?(%Role{system?: true}), do: false
  defp editable?(_role), do: true

  # "Operador (cópia)", then "(cópia 2)" when that one exists too.
  defp copy_name(name, roles) do
    taken = MapSet.new(roles, &String.downcase(&1.name))
    base = gettext("%{name} (copy)", name: name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> gettext("%{name} (copy %{n})", name: name, n: n)
    end)
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
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
    users = Accounts.list_users()

    socket
    |> assign(:roles, roles)
    |> assign(:holders, Enum.group_by(users, & &1.role_id))
    |> assign(:users_count, length(users))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp checked?(form, permission), do: to_string(permission) in selected(form)

  defp selected(form) do
    (Phoenix.HTML.Form.input_value(form, :permissions) || []) |> Enum.map(&to_string/1)
  end

  # Granted only because a "manage" permission implies it: shown on, but not
  # a switch of its own.
  # A "view" held explicitly next to its "manage" is shown the same way (the
  # board's "incluído"); a hidden input keeps it in the form, so turning the
  # manage off leaves the view where it was.
  defp implied?(form, permission) do
    permission = to_string(permission)
    permission in Permission.expand(List.delete(selected(form), permission))
  end

  defp granted_count(permissions) do
    permissions
    |> Enum.map(&to_string/1)
    |> Permission.expand()
    |> Enum.uniq()
    |> Enum.count(&Permission.valid?/1)
  end

  defp view_only?(role) do
    role.permissions != [] and
      Enum.all?(role.permissions, &String.starts_with?(to_string(&1), "view_"))
  end

  defp role_look(%Role{system?: true} = role) do
    cond do
      Role.can?(role, :manage_users) -> {"hero-shield-check", "bg-primary/12 text-primary"}
      Role.can?(role, :manage_rules) -> {"hero-bolt", "bg-allies/14 text-allies"}
      true -> {"hero-eye", "bg-secondary text-subtle"}
    end
  end

  defp role_look(role) do
    if Role.can?(role, :manage_progression),
      do: {"hero-trophy", "bg-accent/13 text-accent"},
      else: {"hero-star", "bg-accent/13 text-accent"}
  end

  # Permissions that differ from what is saved, for the "editado" marks.
  defp changed(form, role) do
    saved = MapSet.new(role.permissions || [], &to_string/1)
    now = MapSet.new(selected(form))
    MapSet.union(MapSet.difference(saved, now), MapSet.difference(now, saved))
  end

  # The sheet as the board lays it out: an area, then one row per thing a
  # role can touch with its "view" and "manage" switch side by side.
  # Permissions the layout does not know yet are appended under their group,
  # so a new one still shows up here.
  defp sheet do
    known = [
      {:servers, gettext("Servers"), gettext("address, API key, stream"), :view_servers,
       :manage_servers},
      {:rules, gettext("Rules"), gettext("create, simulate, publish, restore versions"),
       :view_rules, :manage_rules},
      {nil, gettext("Executions"), gettext("what each rule did, and why it did not"),
       :view_executions, nil},
      {:live, gettext("Live feed"), gettext("the servers' events in real time"), :view_live_feed,
       nil},
      {nil, gettext("Statistics"), gettext("scoreboard, squads, match history"), :view_stats,
       nil},
      {:community, gettext("Progression"), gettext("seasons, achievements, medals"),
       :view_progression, :manage_progression},
      {:tickets, gettext("Tickets"), gettext("answer, assign, close, internal notes"),
       :view_tickets, :manage_tickets},
      {nil, gettext("Act on players"),
       gettext("message, punish, kick, ban, watchlist and VIP from the player pages and tickets"),
       nil, :manage_players},
      {:admin, gettext("Integrations"), gettext("Discord webhooks"), nil, :manage_integrations},
      {nil, gettext("Users"), gettext("create accounts, limit servers, switch 2FA off"), nil,
       :manage_users},
      {nil, gettext("Roles"), gettext("this page"), nil, :manage_roles}
    ]

    listed = Enum.flat_map(known, fn {_a, _t, _h, view, manage} -> [view, manage] end)

    extra =
      for permission <- Permission.all(), permission not in listed do
        {Permission.group(permission), permission_label(permission), nil,
         if(String.starts_with?(to_string(permission), "view_"), do: permission),
         if(String.starts_with?(to_string(permission), "manage_"), do: permission)}
      end

    Enum.map(known ++ extra, fn {area, title, hint, view, manage} ->
      %{area: area, title: title, hint: hint, view: view, manage: manage}
    end)
  end

  # The last row of an area: the next row starts a new area, or there is none.
  # Rows inside an area sit closer together, as on the board.
  defp group_end?(index) do
    case Enum.at(sheet(), index + 1) do
      nil -> true
      next -> next.area != nil
    end
  end

  defp area_label(:servers), do: gettext("Servers")
  defp area_label(:rules), do: gettext("Rules")
  defp area_label(:live), do: gettext("Live")
  defp area_label(:community), do: gettext("Community")
  defp area_label(:tickets), do: gettext("Tickets")
  defp area_label(:admin), do: gettext("Administration")
  defp area_label(nil), do: nil
  defp area_label(group), do: Labels.permission_group(group)

  defp header_tabs(users_count, roles_count, current_user) do
    if(Accounts.can?(current_user, :manage_users),
      do: [%{label: gettext("Users"), path: ~p"/users", count: users_count, active: false}],
      else: []
    ) ++
      [%{label: gettext("Roles"), path: ~p"/roles", count: roles_count, active: true}]
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Roles")}
      crumb={gettext("Settings / People")}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      tabs={header_tabs(@users_count, length(@roles), @current_user)}
      global_search={false}
      bell={false}
      scope={false}
    >
      <:actions>
        <.link
          id="new-role"
          patch={~p"/roles/new"}
          class="flex h-12 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:bg-secondary"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="max-sm:sr-only">{gettext("New role")}</span>
        </.link>
      </:actions>

      <div class="grid gap-5 lg:grid-cols-[21.25rem_minmax(0,1fr)] xl:min-h-[56.25rem]">
        <section
          id="role-list"
          aria-label={gettext("Role list")}
          class="flex min-h-0 flex-col gap-1.5 rounded-panel bg-base-100 p-4"
        >
          <%= for {title, roles, system?} <- [
                {gettext("Built-in"), Enum.filter(@roles, & &1.system?), true},
                {gettext("Custom"), Enum.reject(@roles, & &1.system?), false}
              ],
              roles != [] or not system? do %>
            <.section_label class={[
              "px-2",
              if(system?, do: "py-1.5", else: "mt-1.5 border-t border-line-soft pb-1.5 pt-3.5")
            ]}>
              {title}
            </.section_label>
            <.link
              :for={role <- roles}
              id={"role-#{role.id}"}
              patch={~p"/roles/#{role}/edit"}
              aria-current={@role && @role.id == role.id && "true"}
              class={[
                "flex items-center gap-3 rounded-[1.125rem] border p-3 transition-colors",
                if(@role && @role.id == role.id,
                  do: "border-line-strong bg-secondary",
                  else: "border-transparent hover:bg-secondary"
                )
              ]}
            >
              <span class={[
                "flex size-[2.375rem] shrink-0 items-center justify-center rounded-xl",
                elem(role_look(role), 1)
              ]}>
                <.icon name={elem(role_look(role), 0)} class="size-[1.125rem]" />
              </span>
              <span class="flex min-w-0 flex-1 flex-col gap-0.5">
                <strong class="text-sm font-semibold leading-tight">{role_label(role)}</strong>
                <span class="truncate text-xs text-muted">
                  {if role.system? and view_only?(role),
                    do: gettext("view only"),
                    else:
                      gettext("%{granted} of %{total}",
                        granted: granted_count(role.permissions),
                        total: length(Permission.all())
                      )} · {ngettext(
                    "%{count} person",
                    "%{count} people",
                    length(Map.get(@holders, role.id, [])),
                    count: length(Map.get(@holders, role.id, []))
                  )}
                </span>
              </span>
              <span
                :if={role.system?}
                class="flex shrink-0 items-center gap-1 rounded-full bg-secondary px-2 py-1 text-[0.6875rem] font-semibold text-subtle"
              >
                <.icon name="hero-lock-closed" class="size-3" /> {gettext("built-in")}
              </span>
              <span
                :if={not role.system?}
                class="shrink-0 rounded-full bg-accent/13 px-2 py-1 text-[0.6875rem] font-semibold text-accent"
              >
                {gettext("custom")}
              </span>
            </.link>
          <% end %>

          <.link
            patch={~p"/roles/new"}
            class="mt-1 flex h-11 items-center justify-center rounded-2xl border border-dashed border-line-strong text-[0.8125rem] transition-colors hover:bg-secondary"
          >
            + {gettext("New role")}
          </.link>

          <span class="flex-1"></span>

          <p class="flex items-start gap-2.5 rounded-[1.125rem] bg-secondary p-3.5 text-xs leading-normal text-subtle">
            <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
            {gettext(
              "Built-in roles do not change. To adjust one, duplicate it and edit the copy. The role gives the permissions; in Users you limit which servers each person reaches."
            )}
          </p>
        </section>

        <section
          :if={@role}
          id="role-editor"
          aria-label={
            if @role.id,
              do: gettext("Permissions of %{name}", name: role_label(@role)),
              else: gettext("New role")
          }
          class="flex min-h-0 flex-col overflow-hidden rounded-panel bg-base-100"
        >
          <.form
            for={@form}
            id="role-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-1 flex-col"
          >
            <div class="flex flex-col gap-3.5 border-b border-line-soft px-5 pb-[1.125rem] pt-[1.375rem] sm:px-[1.625rem]">
              <div class="flex flex-wrap items-center gap-3">
                <%= if editable?(@role) do %>
                  <input
                    type="text"
                    id="role_name"
                    name={@form[:name].name}
                    value={@form[:name].value}
                    placeholder={gettext("Role name")}
                    aria-label={gettext("Name")}
                    required
                    class="min-w-0 max-w-full flex-1 rounded-lg border-0 bg-transparent p-0 font-display text-[1.5rem] font-semibold leading-[1.2] outline-none placeholder:text-muted focus:ring-0 sm:flex-none"
                    size={max(String.length(@form[:name].value || ""), 12)}
                  />
                <% else %>
                  <h2 class="font-display text-[1.5rem] font-semibold leading-[1.2]">
                    {role_label(@role)}
                  </h2>
                <% end %>
                <span
                  :if={@role.system?}
                  class="flex items-center gap-1 rounded-full bg-secondary px-[0.5625rem] py-1 text-[0.6875rem] font-semibold text-subtle"
                >
                  <.icon name="hero-lock-closed" class="size-3" /> {gettext("built-in")}
                </span>
                <span
                  :if={not @role.system?}
                  class="rounded-full bg-accent/13 px-[0.5625rem] py-1 text-[0.6875rem] font-semibold text-accent"
                >
                  {gettext("custom")}
                </span>
                <span class="flex-1"></span>
                <button
                  :if={@role.id}
                  type="button"
                  id="role-duplicate"
                  phx-click="duplicate"
                  class="h-11 rounded-full border border-base-300 bg-secondary px-4 text-sm transition-colors hover:bg-base-300"
                >
                  {gettext("Duplicate")}
                </button>
                <button
                  :if={@role.id && not @role.system?}
                  type="button"
                  id="role-delete"
                  phx-click="delete"
                  phx-value-id={@role.id}
                  data-confirm={gettext("Remove the role \"%{name}\"?", name: @role.name)}
                  class="h-11 rounded-full border border-base-300 bg-secondary px-4 text-sm text-error transition-colors hover:bg-base-300"
                >
                  {gettext("Delete")}
                </button>
                <button
                  :if={editable?(@role)}
                  type="submit"
                  id="role-save"
                  phx-disable-with={gettext("Saving...")}
                  class="h-11 rounded-full bg-[var(--tone-cta)] px-5 text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90"
                >
                  {gettext("Save role")}
                </button>
              </div>
              <p
                :for={message <- Enum.map(@form[:name].errors, &translate_error/1)}
                class="text-xs text-error"
              >
                {message}
              </p>

              <div class="flex flex-wrap items-center gap-4">
                <%= if editable?(@role) do %>
                  <textarea
                    id="role_description"
                    name={@form[:description].name}
                    rows="2"
                    placeholder={gettext("What this role is for, in a sentence")}
                    aria-label={gettext("Description")}
                    class="min-w-0 flex-1 resize-none rounded-lg border-0 bg-transparent p-0 text-sm leading-normal text-subtle outline-none placeholder:text-muted focus:ring-0"
                  >{Phoenix.HTML.Form.normalize_value("textarea", @form[:description].value)}</textarea>
                <% else %>
                  <p class="min-w-0 flex-1 text-sm text-subtle">{@role.description}</p>
                <% end %>
                <.link
                  :if={@role.id && Map.get(@holders, @role.id, []) != []}
                  navigate={~p"/users"}
                  id="role-holders"
                  class="flex shrink-0 items-center gap-2.5 whitespace-nowrap rounded-full bg-secondary py-1.5 pl-1.5 pr-3.5 text-[0.8125rem] font-medium"
                >
                  <span class="flex">
                    <.person_avatar
                      :for={
                        {person, index} <- Enum.with_index(Enum.take(Map.get(@holders, @role.id), 3))
                      }
                      user={person}
                      size="xs"
                      class={["border-2 border-secondary", index > 0 && "-ml-2"]}
                    />
                  </span>
                  {ngettext(
                    "%{count} person has this role",
                    "%{count} people have this role",
                    length(Map.get(@holders, @role.id)),
                    count: length(Map.get(@holders, @role.id))
                  )}
                </.link>
              </div>
            </div>

            <div class="roles-editor-row bg-base-200 px-5 py-3 text-xs text-muted sm:px-[1.625rem]">
              <span class="hidden sm:block">{gettext("Area")}</span>
              <span>{gettext("Permission")}</span>
              <span class="text-center">{gettext("View")}</span>
              <span class="text-center">{gettext("Manage")}</span>
            </div>

            <div class="flex min-h-0 flex-1 flex-col px-5 py-1 sm:px-[1.625rem]">
              <div
                :for={{row, index} <- Enum.with_index(sheet())}
                class={[
                  "roles-editor-row",
                  if(row.area, do: "pt-3", else: "pt-1.5"),
                  if(group_end?(index), do: "pb-3", else: "pb-1.5"),
                  index > 0 && row.area && "border-t border-line-soft"
                ]}
              >
                <span class="hidden text-[0.8125rem] font-semibold sm:block">
                  {area_label(row.area)}
                </span>
                <span class="flex min-w-0 flex-col gap-0.5">
                  <span class="flex items-center gap-2 text-sm">
                    {row.title}
                    <span
                      :if={
                        MapSet.size(changed(@form, @role)) > 0 and
                          Enum.any?(
                            [row.view, row.manage],
                            &(&1 && to_string(&1) in changed(@form, @role))
                          )
                      }
                      class="rounded-full bg-primary/14 px-2 py-0.5 text-[0.6875rem] font-semibold text-primary"
                    >
                      {gettext("edited")}
                    </span>
                  </span>
                  <span :if={row.hint} class="text-xs text-muted">{row.hint}</span>
                </span>
                <span class="flex justify-center">
                  <.permission_switch
                    :if={row.view}
                    form={@form}
                    permission={row.view}
                    disabled={not editable?(@role)}
                  />
                  <span :if={is_nil(row.view)} class="text-[0.8125rem] text-muted">
                    <span aria-hidden="true">—</span>
                    <span class="sr-only">{gettext("Does not apply")}</span>
                  </span>
                </span>
                <span class="flex justify-center">
                  <.permission_switch
                    :if={row.manage}
                    form={@form}
                    permission={row.manage}
                    disabled={not editable?(@role)}
                  />
                  <span :if={is_nil(row.manage)} class="text-[0.8125rem] text-muted">
                    <span aria-hidden="true">—</span>
                    <span class="sr-only">{gettext("Does not apply")}</span>
                  </span>
                </span>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-4 border-t border-line-soft px-5 py-4 text-xs text-muted sm:px-[1.625rem]">
              <span class="flex items-center gap-2">
                <span class="settings-implied-chip" aria-hidden="true"></span>
                {gettext("Manage already includes View")}
              </span>
              <span>— {gettext("does not apply")}</span>
              <span class="flex-1"></span>
              <span id="role-count">
                <strong class="font-semibold text-base-content">
                  {gettext("%{granted} of %{total}",
                    granted: granted_count(selected(@form)),
                    total: length(Permission.all())
                  )}
                </strong>
                {gettext("permissions")}
                <span :if={@role.id && MapSet.size(changed(@form, @role)) > 0}>
                  · {ngettext(
                    "%{count} unsaved change",
                    "%{count} unsaved changes",
                    MapSet.size(changed(@form, @role)),
                    count: MapSet.size(changed(@form, @role))
                  )}
                </span>
              </span>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :permission, :atom, required: true
  attr :disabled, :boolean, default: false

  defp permission_switch(assigns) do
    ~H"""
    <%= if implied?(@form, @permission) do %>
      <span class="flex flex-col items-center gap-[0.1875rem]">
        <input
          :if={checked?(@form, @permission)}
          type="hidden"
          name="role[permissions][]"
          value={@permission}
        />
        <span
          class="settings-switch settings-switch--implied"
          role="switch"
          aria-checked="true"
          aria-disabled="true"
          aria-label={gettext("%{permission}, included", permission: permission_label(@permission))}
          title={gettext("Included in manage")}
        >
          <span></span>
        </span>
        <span class="text-[0.6875rem] text-muted">{gettext("included")}</span>
      </span>
    <% else %>
      <label
        class={["settings-switch", @disabled && "cursor-not-allowed opacity-70"]}
        title={permission_label(@permission)}
      >
        <input
          type="checkbox"
          id={"role-permission-#{@permission}"}
          name="role[permissions][]"
          value={@permission}
          checked={checked?(@form, @permission)}
          disabled={@disabled}
          role="switch"
          aria-label={permission_label(@permission)}
        />
        <span></span>
      </label>
    <% end %>
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
