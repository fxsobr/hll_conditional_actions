defmodule HllConditionalActionsWeb.UserLive.Index do
  @moduledoc """
  User administration (the Users board): who can sign in, with which role,
  on which servers, and whether their second factor is on.

  The table fills the page; picking a row opens the editor beside it
  (`/users/:id/edit`), and "Criar usuário" opens the same panel empty.

  The role decides *what* an account may do; the server list decides *where*.
  Assigning no servers means every server ("Todos, inclusive os que forem
  adicionados"), which keeps a single-community install from having to
  configure anything.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_users}}

  import HllConditionalActionsWeb.SettingsComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Enrolments
  alias HllConditionalActions.Accounts.Role
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Servers

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Users"))
     |> assign(:servers, Servers.list_servers())
     |> assign(:roles, Accounts.list_roles())
     |> assign(:selected_servers, [])
     |> assign(:confirm_two_factor_off, false)
     |> assign(:search, "")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:confirm_two_factor_off, false)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:user, nil) |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    user = %User{servers: [], must_change_password?: true}

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
  def handle_event("validate", %{"user" => params} = all, socket) do
    changeset = Accounts.change_user(socket.assigns.user, params)

    {:noreply,
     socket
     |> assign(:selected_servers, selection(all["_target"], params))
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, :search, String.slice(search, 0, 80))}
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
        {:ok, updated} = Accounts.update_user(user, %{active: not user.active})

        # A deactivated account is signed out everywhere, now.
        if not updated.active, do: sign_out_everywhere(updated)

        socket = load(socket)

        socket =
          if socket.assigns[:user] && socket.assigns.user.id == updated.id,
            do: assign(socket, :user, Accounts.get_user!(updated.id)),
            else: socket

        {:noreply, socket}
    end
  end

  def handle_event("ask_two_factor_off", _params, socket) do
    {:noreply, assign(socket, :confirm_two_factor_off, true)}
  end

  def handle_event("cancel_two_factor_off", _params, socket) do
    {:noreply, assign(socket, :confirm_two_factor_off, false)}
  end

  # The escape hatch for a phone that is gone and recovery codes that went with
  # it. Deliberately available to anybody who can manage users, and deliberately
  # loud in the confirmation: it drops an account back to a password alone.
  def handle_event("clear_two_factor", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:ok, _user} = TwoFactor.disable(user)
    Enrolments.clear(user)

    socket =
      socket
      |> put_flash(
        :info,
        gettext("Two factor switched off for %{username}.", username: user.username)
      )
      |> assign(:confirm_two_factor_off, false)
      |> load()

    socket =
      if socket.assigns[:user] && socket.assigns.user.id == user.id,
        do: assign(socket, :user, Accounts.get_user!(user.id)),
        else: socket

    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    if to_string(user.id) == to_string(socket.assigns.current_user.id) do
      {:noreply, put_flash(socket, :error, gettext("You cannot remove your own account."))}
    else
      case Accounts.delete_user(user) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("User removed."))
           |> load()
           |> push_patch(to: ~p"/users")}

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

  defp sign_out_everywhere(user) do
    for id <- Sessions.revoke_all(user) do
      HllConditionalActionsWeb.Endpoint.broadcast(Sessions.socket_id(id), "disconnect", %{})
    end
  end

  # Ticking "every server" clears the list; ticking a server unticks "every
  # server". An empty list is what "every server" means.
  defp selection(["user", "all_servers"], params) do
    if params["all_servers"] == "true", do: [], else: server_ids(params)
  end

  defp selection(_target, params), do: server_ids(params)

  # Checkbox groups drop the key entirely when nothing is ticked.
  defp server_ids(params), do: params |> Map.get("server_ids", []) |> Enum.reject(&(&1 == ""))

  defp save_user(socket, %User{id: nil}, params) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        {:ok, _user} = Accounts.set_user_servers(user, socket.assigns.selected_servers)

        {:noreply,
         socket
         |> put_flash(:info, gettext("User created."))
         |> load()
         |> push_patch(to: ~p"/users/#{user}/edit")}

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
        {:ok, _user} = Accounts.set_user_servers(updated, socket.assigns.selected_servers)

        # A new password set by an administrator ends every session the
        # account had open.
        if Map.has_key?(params, "password"), do: sign_out_everywhere(updated)

        {:noreply,
         socket
         |> put_flash(:info, gettext("User updated."))
         |> load()
         |> push_patch(to: ~p"/users/#{updated}/edit")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp load(socket) do
    socket
    |> assign(:users, Accounts.list_users())
    |> assign(:two_factor_ids, TwoFactor.enabled_user_ids())
    |> assign(:pending_two_factor, Enrolments.pending_since())
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  # Narrows the table by name, username or email, as the admin types.
  defp visible_users(users, search) do
    case search |> String.trim() |> String.downcase() do
      "" ->
        users

      term ->
        Enum.filter(users, fn user ->
          [user.username, user.name, user.email]
          |> Enum.reject(&is_nil/1)
          |> Enum.any?(&String.contains?(String.downcase(&1), term))
        end)
    end
  end

  defp two_factor_state(user, on_ids, pending) do
    cond do
      MapSet.member?(on_ids, user.id) -> :on
      Map.has_key?(pending, user.id) -> :pending
      true -> :off
    end
  end

  # The active accounts that sign in with a password alone, other than me.
  defp exposed(users, on_ids, me) do
    Enum.filter(users, &(&1.active and &1.id != me.id and not MapSet.member?(on_ids, &1.id)))
  end

  defp short_date(nil), do: "–"
  defp short_date(at), do: Calendar.strftime(at, "%d/%m")

  defp self?(user, current_user), do: to_string(user.id) == to_string(current_user.id)

  defp selected?(user, selected), do: selected && selected.id == user.id

  # The role that can hand out accounts wears the signal colour, the other
  # built-in ones their own, and custom roles share the engine lavender.
  defp role_tone(%Role{system?: true} = role) do
    cond do
      Role.can?(role, :manage_users) -> "bg-primary/12 text-primary"
      Role.can?(role, :manage_rules) -> "bg-allies/14 text-allies"
      true -> "bg-base-300 text-subtle"
    end
  end

  defp role_tone(%Role{}), do: "bg-accent/13 text-accent"
  defp role_tone(_role), do: "bg-base-300 text-subtle"

  defp role_checked?(form, role_id), do: to_string(form[:role_id].value) == to_string(role_id)

  # "BR #1 Público" -> "BR #1": the chips only need the number.
  defp short_name(name) do
    case Regex.run(~r/^(.*?#\s?\d+)/u, name) do
      [_all, short] -> short
      nil -> name
    end
  end

  defp header_tabs(users, current_user, roles_count) do
    [
      %{label: gettext("Users"), path: ~p"/users", count: length(users), active: true}
      | if(Accounts.can?(current_user, :manage_roles),
          do: [%{label: gettext("Roles"), path: ~p"/roles", count: roles_count, active: false}],
          else: []
        )
    ]
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Users")}
      crumb={gettext("Settings / People")}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      tabs={header_tabs(@users, @current_user, length(@roles))}
      bell={false}
      scope={false}
    >
      <:search>
        <form
          id="user-search"
          phx-change="search"
          phx-submit="search"
          role="search"
          class="hidden md:block"
        >
          <label class="flex h-12 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 px-[1.125rem] text-muted focus-within:border-primary/60 md:w-65">
            <.icon name="hero-magnifying-glass" class="size-[1.125rem] shrink-0" />
            <span class="sr-only">{gettext("Search users")}</span>
            <input
              type="search"
              name="search"
              value={@search}
              placeholder={gettext("Search by name or email")}
              autocomplete="off"
              phx-debounce="200"
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:outline-none focus:ring-0"
            />
          </label>
        </form>
      </:search>
      <:actions>
        <.link
          id="new-user"
          patch={~p"/users/new"}
          class="flex h-12 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:bg-secondary"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="max-sm:sr-only">{gettext("Create user")}</span>
        </.link>
      </:actions>

      <div class={[
        "grid gap-5",
        @live_action in [:new, :edit] && "xl:grid-cols-[minmax(0,1fr)_25rem]",
        "xl:min-h-[56.25rem]"
      ]}>
        <section
          id="user-list"
          aria-label={gettext("Accounts")}
          class="flex min-h-0 flex-col gap-0.5 rounded-panel bg-base-100 px-2 pb-4 pt-3 sm:px-4"
        >
          <div class="hidden lg:block" aria-hidden="true">
            <div class="users-grid px-3 py-2.5 text-xs text-muted">
              <span>{gettext("Person")}</span>
              <span>{gettext("Email")}</span>
              <span>{gettext("Role")}</span>
              <span>{gettext("Servers")}</span>
              <span>2FA</span>
              <span>{gettext("Last sign in")}</span>
              <span>{gettext("Active")}</span>
            </div>
          </div>

          <ul id="users" class="flex flex-col gap-0.5">
            <li
              :if={visible_users(@users, @search) == []}
              class="px-4 py-10 text-center text-sm text-muted"
            >
              {gettext("Nobody matches this search.")}
            </li>

            <li
              :for={user <- visible_users(@users, @search)}
              id={"user-#{user.id}"}
              class={[
                "users-grid relative rounded-2xl border px-3 py-3.5 transition-colors",
                if(selected?(user, @user),
                  do: "border-line-strong bg-secondary",
                  else: "border-transparent border-t-line-soft hover:bg-secondary"
                )
              ]}
            >
              <div class="flex min-w-0 items-center gap-2.5">
                <.person_avatar
                  user={user}
                  size="sm"
                  class={
                    not user.active &&
                      "border border-dashed border-line-strong !bg-secondary !text-muted"
                  }
                />
                <div class="flex min-w-0 flex-col gap-px">
                  <.link
                    patch={~p"/users/#{user}/edit"}
                    class={[
                      "truncate text-sm font-semibold after:absolute after:inset-0",
                      not user.active && "text-subtle"
                    ]}
                  >
                    {user.name || user.username}
                    <span
                      :if={self?(user, @current_user)}
                      class="text-[0.6875rem] font-medium text-muted"
                    >
                      {gettext("you")}
                    </span>
                  </.link>
                  <span class="truncate font-mono text-xs text-muted">{user.username}</span>
                </div>
              </div>

              <span class={[
                "hidden truncate text-[0.8125rem] lg:block",
                if(user.active, do: "text-subtle", else: "text-muted")
              ]}>
                {user.email || "–"}
              </span>

              <span class="hidden min-w-0 lg:block">
                <span class={[
                  "inline-flex max-w-full truncate whitespace-nowrap rounded-full px-[0.5625rem] py-[0.3125rem] text-[0.6875rem] font-semibold",
                  role_tone(user.role),
                  not user.active && "opacity-60"
                ]}>
                  {user.role && user.role.name}
                </span>
              </span>

              <span class="hidden min-w-0 flex-wrap gap-1 lg:flex">
                <span :if={user.servers == []} class="text-[0.8125rem]">
                  {gettext("All")}
                </span>
                <span
                  :for={server <- user.servers}
                  title={server.name}
                  class={[
                    "max-w-full truncate rounded-full px-[0.4375rem] py-[0.1875rem] text-[0.6875rem]",
                    if(user.active, do: "bg-base-300", else: "bg-secondary text-subtle")
                  ]}
                >
                  {short_name(server.name)}
                </span>
              </span>

              <span class="hidden items-center gap-1.5 text-xs lg:flex">
                <.two_factor_state
                  state={two_factor_state(user, @two_factor_ids, @pending_two_factor)}
                  active={user.active}
                />
              </span>

              <span class={[
                "hidden truncate font-mono text-xs lg:block",
                if(user.active, do: "text-subtle", else: "text-muted")
              ]}>
                <%= if user.last_login_at do %>
                  <.local_time id={"user-#{user.id}-login"} at={user.last_login_at} />
                <% else %>
                  {gettext("never")}
                <% end %>
              </span>

              <span class="relative z-10 flex justify-end lg:justify-start">
                <button
                  type="button"
                  id={"user-#{user.id}-active"}
                  role="switch"
                  aria-checked={to_string(user.active)}
                  aria-label={gettext("Account of %{name} active", name: user.name || user.username)}
                  disabled={self?(user, @current_user)}
                  phx-click="toggle_active"
                  phx-value-id={user.id}
                  class={[
                    "relative inline-flex h-6 w-10 cursor-pointer items-center rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-55",
                    if(user.active, do: "bg-primary", else: "bg-line-raised")
                  ]}
                >
                  <span class={[
                    "absolute left-0 size-[1.125rem] rounded-full transition-transform",
                    if(user.active,
                      do: "translate-x-[1.1875rem] bg-primary-content",
                      else: "translate-x-[0.1875rem] bg-muted"
                    )
                  ]}></span>
                </button>
              </span>
            </li>
          </ul>

          <span class="flex-1"></span>

          <.exposure_banner
            exposed={exposed(@users, @two_factor_ids, @current_user)}
            me={two_factor_state(@current_user, @two_factor_ids, @pending_two_factor)}
          />

          <p class="px-1 pt-2.5 text-xs text-muted">
            {gettext("Deactivated accounts cannot sign in, but what they did stays in the history.")}
          </p>
        </section>

        <.editor
          :if={@live_action in [:new, :edit]}
          user={@user}
          form={@form}
          roles={@roles}
          servers={@servers}
          selected_servers={@selected_servers}
          current_user={@current_user}
          two_factor={
            if @user.id,
              do: two_factor_state(@user, @two_factor_ids, @pending_two_factor),
              else: :off
          }
          confirm_two_factor_off={@confirm_two_factor_off}
          can_manage_roles={Accounts.can?(@current_user, :manage_roles)}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :state, :atom, required: true
  attr :active, :boolean, default: true

  defp two_factor_state(%{active: false} = assigns) do
    ~H"""
    <span class="text-muted">
      {if @state == :on, do: gettext("on"), else: "–"}
    </span>
    """
  end

  defp two_factor_state(assigns) do
    ~H"""
    <%= case @state do %>
      <% :on -> %>
        <span class="flex items-center gap-1.5 font-semibold text-primary">
          <.icon name="hero-check" class="size-3.5" /> {gettext("on")}
        </span>
      <% :pending -> %>
        <span class="flex items-center gap-1.5 font-semibold text-warning">
          <span class="size-[0.4375rem] rounded-full border-[1.5px] border-dashed border-warning"></span>
          {gettext("setting up")}
        </span>
      <% :off -> %>
        <span class="flex items-center gap-1.5 font-semibold text-warning">
          <.icon name="hero-exclamation-triangle" class="size-3.5" /> {gettext("off")}
        </span>
    <% end %>
    """
  end

  attr :exposed, :list, required: true
  attr :me, :atom, required: true

  # "Bruno está sem 2FA e você ainda não terminou de configurar o seu. Esta
  # ferramenta pode expulsar e banir." - said only when somebody really is.
  defp exposure_banner(assigns) do
    ~H"""
    <div
      :if={@exposed != [] or @me != :on}
      id="users-two-factor-warning"
      class="flex flex-wrap items-center gap-3 rounded-[1.125rem] border border-warning/25 bg-warning/8 px-4 py-3.5"
    >
      <.icon name="hero-lock-closed" class="size-4 shrink-0 text-warning" />
      <span class="min-w-0 flex-1 text-[0.8125rem] leading-[1.45]">
        <%= case @exposed do %>
          <% [] -> %>
          <% [one] -> %>
            {gettext("%{name} signs in without 2FA", name: one.name || one.username)}
          <% many -> %>
            {ngettext(
              "%{count} account signs in without 2FA",
              "%{count} accounts sign in without 2FA",
              length(many),
              count: length(many)
            )}
        <% end %>
        <%= cond do %>
          <% @me == :pending and @exposed != [] -> %>
            {gettext("and you have not finished setting up yours.")}
          <% @me == :pending -> %>
            {gettext("You have not finished setting up your 2FA.")}
          <% @me == :off and @exposed != [] -> %>
            {gettext("and neither do you.")}
          <% @me == :off -> %>
            {gettext("Your account signs in without 2FA.")}
          <% true -> %>
            .
        <% end %>
        {gettext("This tool can kick and ban.")}
      </span>
      <.link
        :if={@me != :on}
        navigate={~p"/account"}
        class="whitespace-nowrap text-[0.8125rem] font-semibold text-warning hover:underline"
      >
        {if @me == :pending, do: gettext("Finish mine"), else: gettext("Set up mine")}
      </.link>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :form, :any, required: true
  attr :roles, :list, required: true
  attr :servers, :list, required: true
  attr :selected_servers, :list, required: true
  attr :current_user, :map, required: true
  attr :two_factor, :atom, required: true
  attr :confirm_two_factor_off, :boolean, default: false
  attr :can_manage_roles, :boolean, default: false

  defp editor(assigns) do
    ~H"""
    <section
      id="user-editor"
      aria-label={
        if @user.id,
          do: gettext("Edit %{name}", name: @user.name || @user.username),
          else: gettext("Create user")
      }
      class="flex min-h-0 flex-col rounded-panel bg-base-100 p-[1.375rem]"
    >
      <.form
        for={@form}
        id="user-form"
        phx-change="validate"
        phx-submit="save"
        class="settings-form flex flex-1 flex-col gap-4"
      >
        <div class="flex items-center gap-3">
          <.person_avatar :if={@user.id} user={@user} class="size-12 text-[0.9375rem]" />
          <span
            :if={is_nil(@user.id)}
            class="flex size-12 shrink-0 items-center justify-center rounded-full bg-primary/12 text-primary"
          >
            <.icon name="hero-user-plus" class="size-5" />
          </span>
          <div class="flex min-w-0 flex-1 flex-col gap-0.5">
            <h2 class="truncate font-display text-[1.375rem] font-semibold">
              {if @user.id, do: @user.name || @user.username, else: gettext("New user")}
            </h2>
            <span :if={@user.id} class="truncate text-xs text-muted">
              <span class="font-mono">{@user.username}</span>
              · {gettext("created on")}
              {short_date(@user.inserted_at)}
              <span :if={@user.last_login_at}>
                · {gettext("signed in at")}
                <.clock
                  id="user-editor-login"
                  at={@user.last_login_at}
                  class="font-mono"
                />
              </span>
            </span>
            <span :if={is_nil(@user.id)} class="text-xs text-muted">
              {gettext("They choose their own password at the first sign in.")}
            </span>
          </div>
          <.link
            patch={~p"/users"}
            id="user-editor-close"
            aria-label={gettext("Close editing")}
            class="flex size-10 shrink-0 items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>

        <%!-- A new account needs a name and a first password; an existing
              one keeps them here, folded, for when they change. --%>
        <details
          id="user-account-fields"
          open={is_nil(@user.id)}
          class="group rounded-[0.875rem] border border-line-raised"
        >
          <summary class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2.5 text-[0.8125rem] font-medium text-subtle [&::-webkit-details-marker]:hidden">
            {gettext("Name, e-mail and password")}
            <.icon
              name="hero-chevron-down"
              class="size-4 transition-transform group-open:rotate-180"
            />
          </summary>
          <div class="flex flex-col gap-3 px-3 pb-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:username]}
                type="text"
                label={gettext("Username")}
                no_margin
                required
              />
              <.input field={@form[:name]} type="text" label={gettext("Full name")} no_margin />
            </div>
            <.input field={@form[:email]} type="email" label={gettext("Email")} no_margin />
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:password]}
                type="password"
                label={
                  if @user.id, do: gettext("Temporary password"), else: gettext("First password")
                }
                autocomplete="new-password"
                placeholder={if @user.id, do: gettext("Leave blank to keep it")}
                no_margin
              />
              <.input
                field={@form[:password_confirmation]}
                type="password"
                label={gettext("Confirm password")}
                autocomplete="new-password"
                no_margin
              />
            </div>
          </div>
        </details>

        <fieldset class="flex flex-col gap-2">
          <legend class="mb-2 flex w-full items-center justify-between gap-2 text-[0.8125rem] font-medium text-subtle">
            {gettext("Role")}
            <.link
              :if={@can_manage_roles}
              navigate={~p"/roles"}
              class="text-xs font-normal text-primary hover:underline"
            >
              {gettext("What each role can do")}
            </.link>
          </legend>
          <div id="user-role-choices" class="grid grid-cols-2 gap-1.5">
            <label
              :for={role <- @roles}
              class={[
                "flex h-10 cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 text-[0.8125rem] transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary/50",
                if(role_checked?(@form, role.id),
                  do: "border-primary bg-primary/8 font-semibold",
                  else: "border-line-raised bg-secondary hover:border-line-strong"
                )
              ]}
            >
              <input
                type="radio"
                name={@form[:role_id].name}
                value={role.id}
                checked={role_checked?(@form, role.id)}
                class="sr-only"
              />
              <span class="truncate">{role.name}</span>
              <.icon
                :if={role_checked?(@form, role.id)}
                name="hero-check"
                class="size-4 shrink-0 text-primary"
              />
            </label>
          </div>
          <p
            :for={message <- Enum.map(@form[:role_id].errors, &translate_error/1)}
            class="text-xs text-error"
          >
            {message}
          </p>
        </fieldset>

        <fieldset :if={@servers != []} class="flex flex-col gap-1.5">
          <legend class="mb-2 text-[0.8125rem] font-medium text-subtle">
            {gettext("Servers this account reaches")}
          </legend>
          <label
            id="user-all-servers"
            class={[
              "flex h-9 cursor-pointer items-center gap-2.5 rounded-xl bg-secondary px-3 text-[0.8125rem]",
              @selected_servers != [] && "text-subtle"
            ]}
          >
            <input type="hidden" name="user[all_servers]" value="false" />
            <input
              type="checkbox"
              name="user[all_servers]"
              value="true"
              checked={@selected_servers == []}
              class="settings-check"
            />
            {gettext("All, including the ones added later")}
          </label>
          <input type="hidden" name="user[server_ids][]" value="" />
          <div class="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
            <label
              :for={server <- @servers}
              title={server.name}
              class={[
                "flex h-9 min-w-0 cursor-pointer items-center gap-2 rounded-xl bg-secondary px-2.5 text-[0.8125rem]",
                to_string(server.id) not in @selected_servers && "text-subtle"
              ]}
            >
              <input
                type="checkbox"
                name="user[server_ids][]"
                value={server.id}
                checked={to_string(server.id) in @selected_servers}
                class="settings-check"
              />
              <span class="truncate">{short_name(server.name)}</span>
            </label>
          </div>
        </fieldset>

        <label class="flex cursor-pointer items-center gap-2.5 rounded-[0.875rem] border border-line-raised p-3 text-[0.8125rem]">
          <input type="hidden" name={@form[:must_change_password?].name} value="false" />
          <input
            type="checkbox"
            id="user-must-change"
            name={@form[:must_change_password?].name}
            value="true"
            checked={
              Phoenix.HTML.Form.normalize_value("checkbox", @form[:must_change_password?].value)
            }
            class="settings-check"
          />
          <span class="flex flex-col gap-0.5">
            <span>{gettext("Ask for a new password at the next sign in")}</span>
            <span class="text-xs text-muted">{gettext("They choose a new one before getting in")}</span>
          </span>
        </label>

        <.two_factor_box
          :if={@user.id}
          user={@user}
          state={@two_factor}
          confirm={@confirm_two_factor_off}
        />

        <span class="flex-1"></span>

        <div class="flex gap-2">
          <button
            :if={@user.id && not self?(@user, @current_user)}
            type="button"
            id="user-toggle-active"
            phx-click="toggle_active"
            phx-value-id={@user.id}
            class="flex h-12 items-center rounded-full border border-base-300 bg-secondary px-[1.125rem] text-sm transition-colors hover:bg-base-300"
          >
            {if @user.active, do: gettext("Deactivate account"), else: gettext("Activate account")}
          </button>
          <button
            type="submit"
            id="user-save"
            phx-disable-with={gettext("Saving...")}
            class="flex h-12 flex-1 items-center justify-center rounded-full bg-[var(--tone-cta)] px-5 text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90"
          >
            {if @user.id, do: gettext("Save"), else: gettext("Create user")}
          </button>
        </div>

        <button
          :if={@user.id && not self?(@user, @current_user)}
          type="button"
          id="user-delete"
          phx-click="delete"
          phx-value-id={@user.id}
          data-confirm={gettext("Remove %{username}?", username: @user.username)}
          class="self-start text-[0.8125rem] text-error hover:underline"
        >
          {gettext("Remove user")}
        </button>
      </.form>
    </section>
    """
  end

  attr :user, :map, required: true
  attr :state, :atom, required: true
  attr :confirm, :boolean, default: false

  defp two_factor_box(assigns) do
    ~H"""
    <div
      id="user-two-factor"
      class={[
        "flex flex-col gap-2.5 rounded-[1.125rem] border p-3.5",
        if(@confirm, do: "border-axis/35 bg-axis/6", else: "border-line-raised bg-secondary")
      ]}
    >
      <div class="flex items-center gap-2">
        <strong class="flex-1 text-sm font-semibold">{gettext("Two-step verification")}</strong>
        <span
          :if={@state == :on}
          class="rounded-full bg-primary/12 px-[0.5625rem] py-1 text-[0.6875rem] font-semibold text-primary"
        >
          {gettext("on since")}
          {short_date(@user.totp_confirmed_at)}
        </span>
        <span
          :if={@state == :pending}
          class="rounded-full bg-warning/13 px-[0.5625rem] py-1 text-[0.6875rem] font-semibold text-warning"
        >
          {gettext("being set up")}
        </span>
        <span
          :if={@state == :off}
          class="rounded-full bg-warning/13 px-[0.5625rem] py-1 text-[0.6875rem] font-semibold text-warning"
        >
          {gettext("off")}
        </span>
      </div>

      <%= cond do %>
        <% @state == :on and @confirm -> %>
          <span class="text-[0.8125rem] leading-[1.45] text-subtle">
            {gettext(
              "Switch off %{name}'s 2FA? They will sign in with the password alone until they turn it on again in My account. Use it when they lose their phone and their recovery codes.",
              name: @user.name || @user.username
            )}
          </span>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="cancel_two_factor_off"
              class="h-10 flex-1 rounded-full border border-base-300 bg-base-100 text-[0.8125rem]"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="button"
              id="user-two-factor-off"
              phx-click="clear_two_factor"
              phx-value-id={@user.id}
              class="h-10 flex-1 rounded-full bg-axis text-[0.8125rem] font-semibold text-[#2A1405]"
            >
              {gettext("Yes, switch 2FA off")}
            </button>
          </div>
        <% @state == :on -> %>
          <span class="text-[0.8125rem] leading-[1.45] text-subtle">
            {gettext(
              "For when they lose their phone and their recovery codes: switching it off lets them in with the password alone until they set it up again."
            )}
          </span>
          <button
            type="button"
            id="user-two-factor-ask"
            phx-click="ask_two_factor_off"
            class="h-10 w-fit rounded-full border border-base-300 bg-base-100 px-4 text-[0.8125rem]"
          >
            {gettext("Switch 2FA off")}
          </button>
        <% @state == :pending -> %>
          <span class="text-[0.8125rem] leading-[1.45] text-subtle">
            {gettext("They started it and have not confirmed a code yet. It is set up in My account.")}
          </span>
        <% true -> %>
          <span class="text-[0.8125rem] leading-[1.45] text-subtle">
            {gettext("Each person turns it on in My account, with an authenticator app.")}
          </span>
      <% end %>
    </div>
    """
  end
end
