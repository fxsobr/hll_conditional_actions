defmodule HllConditionalActionsWeb.ServerLive.Index do
  @moduledoc """
  Lists the CRCON servers and hosts the create/edit form in a modal.

  Viewing needs `:view_servers`; every mutating action re-checks
  `:manage_servers` server side, because hiding a button is presentation, not
  authorization.

  ## Saving is gated on a verified connection

  A server cannot be saved until its credentials have been checked, and the
  check has to pass the least-privilege review in
  `HllConditionalActions.Crcon.Permissions`. Two reasons:

    * an API key that does not work produces a server that silently does
      nothing, and the only symptom is an empty event feed hours later
    * an API key with more rights than this app uses turns a bug here, or a
      leaked database, into full control of the game server

  Editing the URL or the key clears the verification, so what was approved is
  always what gets saved.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_servers}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Crcon.Permissions
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Servers.subscribe()

    {:ok,
     socket
     |> assign(:form_params, %{})
     |> reset_check()
     |> load_servers()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Servers"))
    |> assign(:server, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    if Accounts.can?(socket.assigns.current_user, :manage_servers) do
      server = %Server{}

      socket
      |> assign(:page_title, gettext("New server"))
      |> assign(:server, server)
      |> assign(:form_params, %{})
      |> reset_check()
      |> assign_form(Servers.change_server(server))
    else
      deny(socket)
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    if Accounts.can?(socket.assigns.current_user, :manage_servers) do
      server = Servers.get_server!(id)

      socket
      |> assign(:page_title, server.name)
      |> assign(:server, server)
      |> assign(:form_params, %{})
      |> reset_check()
      |> assign_form(Servers.change_server(server))
    else
      deny(socket)
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"server" => params}, socket) do
    changeset = Servers.change_server(socket.assigns.server, params)

    socket =
      socket
      |> assign(:form_params, params)
      |> assign_form(Map.put(changeset, :action, :validate))

    # Anything that changes what we would connect to invalidates the approval.
    {:noreply, if(connection_changed?(socket, params), do: reset_check(socket), else: socket)}
  end

  def handle_event("save", %{"server" => params}, socket) do
    cond do
      not Accounts.can?(socket.assigns.current_user, :manage_servers) ->
        {:noreply, deny(socket)}

      not verified?(socket.assigns) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Test the connection before saving, and use a key that passes the review.")
         )}

      true ->
        save_server(socket, socket.assigns.server, params)
    end
  end

  def handle_event("check_connection", _params, socket) do
    attrs = connection_attrs(socket)

    result =
      case Servers.check_connection(attrs) do
        {:ok, info} -> {:ok, info}
        {:error, :incomplete} -> {:error, gettext("Fill in the URL and the API key first.")}
        {:error, error} -> {:error, Exception.message(error)}
      end

    {:noreply,
     socket
     |> assign(:check, result)
     |> assign(:checked_attrs, attrs)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with :ok <- authorize(socket) do
      server = Servers.get_server!(id)
      {:ok, _server} = Servers.update_server(server, %{enabled: not server.enabled})
      {:noreply, load_servers(socket)}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with :ok <- authorize(socket) do
      server = Servers.get_server!(id)
      {:ok, _server} = Servers.delete_server(server)

      {:noreply, socket |> put_flash(:info, gettext("Server removed.")) |> load_servers()}
    else
      _denied -> {:noreply, deny(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({event, _server}, socket)
      when event in [:server_created, :server_updated, :server_deleted] do
    {:noreply, load_servers(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Saving ─────────────────────────────────────────────────────────────────

  defp save_server(socket, %Server{id: nil} = server, params) do
    case Servers.create_server(server_params(server, params)) do
      {:ok, _server} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Server added."))
         |> push_navigate(to: ~p"/servers")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_server(socket, server, params) do
    case Servers.update_server(server, server_params(server, params)) do
      {:ok, _server} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Server updated."))
         |> push_navigate(to: ~p"/servers")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # The API key input is left blank when editing, so an untouched field must
  # not wipe the stored key.
  defp server_params(%Server{id: nil}, params), do: params

  defp server_params(_server, params) do
    case String.trim(Map.get(params, "api_key", "")) do
      "" -> Map.delete(params, "api_key")
      _key -> params
    end
  end

  # ── Connection check ───────────────────────────────────────────────────────

  # Falls back to the stored values so checking an existing server works
  # without retyping its API key, which the form never shows.
  defp connection_attrs(socket) do
    params = socket.assigns[:form_params] || %{}
    server = socket.assigns.server

    %{
      "base_url" => present(params["base_url"]) || server.base_url,
      "api_key" => present(params["api_key"]) || server.api_key
    }
  end

  defp connection_changed?(socket, params) do
    case socket.assigns[:checked_attrs] do
      nil ->
        false

      checked ->
        server = socket.assigns.server

        checked !=
          %{
            "base_url" => present(params["base_url"]) || server.base_url,
            "api_key" => present(params["api_key"]) || server.api_key
          }
    end
  end

  defp reset_check(socket) do
    socket
    |> assign(:check, nil)
    |> assign(:checked_attrs, nil)
  end

  defp verified?(%{check: {:ok, %{permissions: %{ok?: true}}}}), do: true
  defp verified?(_assigns), do: false

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp load_servers(socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    socket
    |> assign(:servers, servers)
    |> assign(:stream_status, Map.new(servers, &{&1.id, LogStream.status(&1.id)}))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp authorize(socket) do
    if Accounts.can?(socket.assigns.current_user, :manage_servers), do: :ok, else: :error
  end

  defp deny(socket) do
    socket
    |> put_flash(:error, gettext("You do not have access to that page."))
    |> push_navigate(to: ~p"/servers")
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("Servers")}
      page_subtitle={gettext("The CRCON instances this engine talks to")}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_servers)}
          link_type="live_patch"
          to={~p"/servers/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("Add server")}
        />
      </:actions>

      <.empty_state
        :if={@servers == []}
        icon="hero-server-stack"
        title={gettext("No servers registered yet.")}
        description={
          gettext(
            "Connect a CRCON instance to start reacting to what happens on your Hell Let Loose servers."
          )
        }
      >
        <:action>
          <.button
            :if={Accounts.can?(@current_user, :manage_servers)}
            link_type="live_patch"
            to={~p"/servers/new"}
            size="sm"
            color="primary"
            label={gettext("Add your first server")}
          />
        </:action>
      </.empty_state>

      <.card :if={@servers != []} padded={false}>
        <.data_table id="servers" rows={@servers}>
          <:col :let={server} label={gettext("Name")}>
            <.link navigate={~p"/servers/#{server}"} class="font-medium hover:underline">
              {server.name}
            </.link>

            <.tone_badge :if={not server.enabled} tone="ghost" size="xs">
              {gettext("Disabled")}
            </.tone_badge>
          </:col>

          <:col :let={server} label={gettext("Game")}>
            <.tone_badge tone="ghost">{Labels.game(server.game)}</.tone_badge>
          </:col>

          <:col :let={server} label={gettext("Address")}>
            <span class="block max-w-xs truncate text-sm text-subtle">
              {server.base_url}
            </span>
          </:col>

          <:col :let={server} label={gettext("Stream")}>
            <span class="inline-flex items-center gap-1.5 text-sm">
              <.status_dot
                tone={stream_tone(@stream_status[server.id], server.enabled)}
                label={Labels.stream_status(@stream_status[server.id])}
              />
              {Labels.stream_status(@stream_status[server.id])}
            </span>
          </:col>

          <:action :let={server}>
            <.button
              link_type="live_patch"
              to={~p"/servers/#{server}/edit"}
              size="xs"
              variant="ghost"
              color="gray"
              label={gettext("Edit")}
            />

            <.row_menu
              :if={Accounts.can?(@current_user, :manage_servers)}
              id={"server-menu-#{server.id}"}
            >
              <.menu_item
                icon="hero-power"
                phx-click="toggle"
                phx-value-id={server.id}
              >
                {if server.enabled, do: gettext("Disable"), else: gettext("Enable")}
              </.menu_item>

              <.menu_item
                tone="error"
                icon="hero-trash"
                phx-click="delete"
                phx-value-id={server.id}
                data-confirm={
                  gettext("Remove %{name} along with its rules and history?", name: server.name)
                }
              >
                {gettext("Remove")}
              </.menu_item>
            </.row_menu>
          </:action>
        </.data_table>
      </.card>

      <.form_modal
        :if={@live_action in [:new, :edit]}
        form={@form}
        server={@server}
        check={@check}
        verified?={verified?(assigns)}
      />
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :server, :any, required: true
  attr :check, :any, default: nil
  attr :verified?, :boolean, default: false

  defp form_modal(assigns) do
    ~H"""
    <.modal
      id="server-modal"
      title={if @server.id, do: gettext("Edit server"), else: gettext("New server")}
      subtitle={gettext("Saving unlocks once the connection test passes.")}
      on_cancel={JS.patch(~p"/servers")}
      class="max-w-2xl"
    >
      <.form
        for={@form}
        id="server-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-3"
      >
        <.input field={@form[:name]} type="text" label={gettext("Name")} required />
        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:game]}
            type="select"
            label={gettext("Game")}
            options={Labels.game_options()}
          />
          <.input
            field={@form[:timezone]}
            type="select"
            label={gettext("Time zone")}
            options={Server.timezone_options(@server)}
          />
        </div>

        <p class="text-xs text-muted">
          {gettext("Time-of-day conditions use this zone, so they follow your players' local time.")}
        </p>

        <.input
          field={@form[:base_url]}
          type="url"
          label={gettext("CRCON address")}
          placeholder="https://rcon.example.com"
          required
        />
        <.input
          field={@form[:api_key]}
          type="password"
          label={gettext("API key")}
          placeholder={if @server.id, do: gettext("Leave blank to keep the current key")}
          autocomplete="off"
        /> <.key_guidance /> <.check_result check={@check} />
        <.input
          field={@form[:log_stream_enabled]}
          type="checkbox"
          label={gettext("Consume the live log stream")}
        /> <.input field={@form[:enabled]} type="checkbox" label={gettext("Enabled")} />
        <.input field={@form[:notes]} type="textarea" label={gettext("Notes")} rows="2" />
        <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
          <.button
            type="button"
            size="sm"
            variant="outline"
            color="gray"
            icon="hero-shield-check"
            phx-click="check_connection"
            phx-disable-with={gettext("Checking...")}
            label={gettext("Test connection")}
          />
          <.button
            link_type="live_patch"
            to={~p"/servers"}
            size="sm"
            variant="ghost"
            color="gray"
            label={gettext("Cancel")}
          />
          <.button
            type="submit"
            size="sm"
            color="primary"
            disabled={not @verified?}
            phx-disable-with={gettext("Saving...")}
            label={gettext("Save")}
          />
        </div>
      </.form>
    </.modal>
    """
  end

  defp stream_tone(_status, false), do: "neutral"
  defp stream_tone(:connected, _enabled), do: "success"
  defp stream_tone(:connecting, _enabled), do: "warning"
  defp stream_tone({:error, _reason}, _enabled), do: "error"
  defp stream_tone(_status, _enabled), do: "neutral"

  defp key_guidance(assigns) do
    assigns =
      assigns
      |> assign(:required, Permissions.required())
      |> assign(:optional, Permissions.allowed() -- Permissions.required())

    ~H"""
    <div class="rounded-box bg-base-200 p-3 text-xs">
      <p class="mb-1 font-medium">{gettext("About the API key")}</p>

      <p class="opacity-70">
        {gettext(
          "Create a CRCON user just for this app and grant it only the permissions below. A key that can do more is refused: it would hand over control of the game server well beyond what these rules need."
        )}
      </p>

      <p class="mt-2 opacity-60">
        {gettext("Wording and names are CRCON's own, so they match its admin screen.")}
      </p>

      <p class="mt-3 font-medium">{gettext("Required")}</p>
      <.permission_row :for={permission <- @required} permission={permission} />
      <details class="mt-3">
        <summary class="cursor-pointer font-medium">
          {gettext("Optional, one per action you intend to use (%{count})",
            count: length(@optional)
          )}
        </summary>

        <div class="mt-2 space-y-1">
          <.permission_row :for={permission <- @optional} permission={permission} />
        </div>
      </details>
    </div>
    """
  end

  attr :permission, :string, required: true

  defp permission_row(assigns) do
    assigns = assign(assigns, :actions, Permissions.actions_for(assigns.permission))

    ~H"""
    <div class="flex flex-wrap items-baseline gap-x-2 py-0.5">
      <span class="opacity-90">{Labels.crcon_permission(@permission)}</span>
      <code class="font-mono opacity-60">{@permission}</code>
      <span :if={@actions != []} class="opacity-50">
        &middot; {Enum.map_join(@actions, ", ", &Labels.action/1)}
      </span>
    </div>
    """
  end

  attr :check, :any, default: nil

  defp check_result(%{check: nil} = assigns), do: ~H""

  defp check_result(%{check: {:error, _message}} = assigns) do
    assigns = assign(assigns, :message, elem(assigns.check, 1))

    ~H"""
    <.alert color="danger" variant="soft" with_icon label={@message} />
    """
  end

  defp check_result(%{check: {:ok, _info}} = assigns) do
    info = elem(assigns.check, 1)
    assigns = assigns |> assign(:info, info) |> assign(:review, info.permissions)

    ~H"""
    <.alert color={if @review.ok?, do: "success", else: "warning"} variant="soft" with_icon>
      <div class="space-y-1">
        <p :if={@info.server}>
          {gettext("Connected to %{name} (%{players}/%{max} players).",
            name: @info.server.name || gettext("the server"),
            players: @info.server.player_count || 0,
            max: @info.server.max_player_count || 0
          )}
        </p>

        <p :if={is_nil(@info.server)}>{gettext("The API key works.")}</p>

        <p :if={@info.user_name} class="opacity-80">
          {gettext("CRCON user:")} <span class="font-mono">{@info.user_name}</span>
        </p>

        <p :if={@review.superuser?} class="font-medium">
          {gettext(
            "This key belongs to a CRCON superuser, which bypasses every permission check. Create a regular user holding only the permissions listed above and issue a key for it."
          )}
        </p>

        <div :if={@review.missing_required != []}>
          <p class="font-medium">{gettext("The key is missing:")}</p>

          <p :for={permission <- @review.missing_required}>
            {Labels.crcon_permission_with_code(permission)}
          </p>
        </div>

        <%!-- A missing read is the quiet failure: CRCON answers 403, the
              engine logs it and the rules simply never match. --%>
        <div :if={@review.missing_reads != []}>
          <p class="font-medium">
            {gettext("The key cannot read everything the engine uses:")}
          </p>

          <p :for={permission <- @review.missing_reads}>
            {Labels.crcon_permission_with_code(permission)} — {Labels.crcon_read_impact(permission)}
          </p>
        </div>

        <div :if={@review.excess != []}>
          <p class="font-medium">{gettext("The key can do more than this app needs. Remove:")}</p>

          <p :for={permission <- @review.excess}>
            {Labels.crcon_permission_with_code(permission)}
          </p>
        </div>

        <p :if={@review.ok? and @review.unavailable_actions != []} class="opacity-80">
          {gettext("Not granted, so a rule using these actions will fail:")}
          <span>{Enum.map_join(@review.unavailable_actions, ", ", &Labels.action/1)}</span>
        </p>
      </div>
    </.alert>
    """
  end
end
