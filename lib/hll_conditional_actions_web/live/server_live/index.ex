defmodule HllConditionalActionsWeb.ServerLive.Index do
  @moduledoc """
  Lists the CRCON servers and hosts the create/edit form in a centred dialog
  (the Servers board).

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

  The test (`HllConditionalActions.Servers.ConnectionTest`) also times the
  answer, reads CRCON's version and opens the log stream for a moment, in the
  background, to say whether it answers.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_servers}}

  import HllConditionalActionsWeb.SettingsComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Briefing.LiveStatus
  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Features
  alias HllConditionalActions.Games
  alias HllConditionalActions.Metrics.History
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.ConnectionTest
  alias HllConditionalActions.Servers.Server
  alias HllConditionalActionsWeb.LiveComponents

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Servers.subscribe()
      # Whether a server is live changes on its own, so the badge has to be
      # told rather than read once. The shared topic covers servers added
      # after this page was opened, which a per server subscription would miss.
      LogStream.subscribe_status()
    end

    socket =
      socket
      |> assign(:form_params, %{})
      |> assign(:live, %{})
      |> reset_check()
      |> load_servers()

    socket =
      if connected?(socket) and socket.assigns.servers != [] do
        servers = socket.assigns.servers
        start_async(socket, :live, fn -> LiveStatus.fetch(servers) end)
      else
        socket
      end

    {:ok, socket}
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

  defp apply_action(socket, :new, params) do
    if Accounts.can?(socket.assigns.current_user, :manage_servers) do
      server = %Server{}

      socket
      # Arriving from the overview's checklist, saving goes back there, where
      # the next step is waiting.
      |> assign(:from_onboarding?, params["from"] == "onboarding")
      |> assign(:page_title, gettext("Add server"))
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
    if Accounts.can?(socket.assigns.current_user, :manage_servers) do
      attrs = connection_attrs(socket)

      result = run_check(attrs)

      socket =
        socket
        |> assign(:check, result)
        |> assign(:checked_attrs, attrs)
        |> assign(:stream_check, if(match?({:ok, _}, result), do: :pending))

      {:noreply, probe_stream(socket, result, attrs)}
    else
      {:noreply, deny(socket)}
    end
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
  def handle_async(:live, {:ok, live}, socket), do: {:noreply, assign(socket, :live, live)}
  def handle_async(:live, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:stream_check, {:ok, result}, socket),
    do: {:noreply, assign(socket, :stream_check, result)}

  def handle_async(:stream_check, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :stream_check, {:error, gettext("the check did not finish")})}

  @impl Phoenix.LiveView
  def handle_info({:crcon_stream_status, server_id, status}, socket) when is_integer(server_id) do
    {:noreply, update(socket, :stream_status, &Map.put(&1, server_id, status))}
  end

  def handle_info({event, _server}, socket)
      when event in [:server_created, :server_updated, :server_deleted] do
    {:noreply, load_servers(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Saving ─────────────────────────────────────────────────────────────────

  defp save_server(socket, %Server{id: nil} = server, params) do
    case Servers.create_server(server_params(server, params)) do
      {:ok, _server} ->
        if socket.assigns[:from_onboarding?] do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Server connected. Next: create your first rule."))
           |> push_navigate(to: ~p"/")}
        else
          {:noreply,
           socket
           |> put_flash(:info, gettext("Server added."))
           |> push_navigate(to: ~p"/servers")}
        end

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

  defp run_check(attrs) do
    case ConnectionTest.run(attrs) do
      {:ok, result} -> {:ok, result}
      {:error, :incomplete} -> {:error, gettext("Fill in the URL and the API key first.")}
      {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  # A connection that answered is then tried on its log stream.
  defp probe_stream(socket, {:ok, _result}, attrs),
    do: start_async(socket, :stream_check, fn -> ConnectionTest.probe_stream(attrs) end)

  defp probe_stream(socket, _result, _attrs), do: socket

  defp reset_check(socket) do
    socket
    |> assign(:check, nil)
    |> assign(:checked_attrs, nil)
    |> assign(:stream_check, nil)
  end

  defp verified?(%{check: {:ok, %{info: %{permissions: %{ok?: true}}}}}), do: true
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
    |> assign(:modules, Features.installed_by_server(Enum.map(servers, & &1.id)))
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

  defp games_in_use(servers) do
    counts = Enum.frequencies_by(servers, & &1.game)
    Enum.map(Games.all(), &{&1, Map.get(counts, &1, 0)})
  end

  defp module_count(modules, server),
    do: modules |> Map.get(server.id, MapSet.new()) |> MapSet.size()

  defp game_option_label(value, label) do
    case to_string(value) do
      "hll" -> "HLL"
      "hllv" -> "HLL Vietnam"
      _other -> label
    end
  end

  defp game_short(:hll), do: "HLL"
  defp game_short(:hllv), do: "HLL Vietnam"
  defp game_short(game), do: to_string(game)

  @doc false
  # "UTC−03:00" for a zone, now.
  def utc_offset(zone) when is_binary(zone) do
    case DateTime.now(zone) do
      {:ok, now} ->
        total = now.utc_offset + now.std_offset
        sign = if total < 0, do: "−", else: "+"
        total = abs(total)

        "UTC#{sign}#{pad(div(total, 3600))}:#{pad(div(rem(total, 3600), 60))}"

      _unknown ->
        nil
    end
  end

  def utc_offset(_zone), do: nil

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # The last four characters of a key, the only part ever shown again.
  defp key_tail(key) when is_binary(key) do
    key = String.trim(key)
    if String.length(key) >= 8, do: String.slice(key, -4, 4)
  end

  defp key_tail(_key), do: nil

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Servers")}
      crumb={gettext("Settings")}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      global_search={false}
      bell={false}
      scope={false}
    >
      <:actions>
        <.link
          :if={Accounts.can?(@current_user, :manage_servers)}
          id="add-server"
          patch={~p"/servers/new"}
          class="flex h-12 items-center gap-2 rounded-full bg-[var(--tone-cta)] px-[1.375rem] text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90"
        >
          <.icon name="hero-plus" class="size-4" />
          <span class="max-sm:sr-only">{gettext("Add server")}</span>
        </.link>
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

      <div :if={@servers != []} class="flex flex-col gap-5">
        <section
          id="server-list"
          aria-label={gettext("Server list")}
          class="flex flex-col rounded-panel bg-base-100 px-2 pb-4 pt-3 sm:px-4"
        >
          <div class="hidden lg:block" aria-hidden="true">
            <div class="servers-grid px-3 py-2.5 text-xs text-muted">
              <span>{gettext("Server")}</span>
              <span>{gettext("Game")}</span>
              <span>{gettext("CRCON address")}</span>
              <span>{gettext("Log stream")}</span>
              <span>{gettext("Modules")}</span>
              <span>{gettext("Time zone")}</span>
              <span></span>
            </div>
          </div>

          <ul id="servers" class="flex flex-col">
            <li
              :for={server <- @servers}
              id={"server-#{server.id}"}
              class="servers-grid group relative rounded-[1.125rem] border-t border-line-soft p-3 transition-colors hover:bg-secondary"
            >
              <div class="flex min-w-0 items-center gap-3.5">
                <img
                  src={server_art(server)}
                  alt=""
                  class="h-12 w-[4.5rem] shrink-0 rounded-[0.875rem] object-cover sm:h-16 sm:w-24"
                  loading="lazy"
                />
                <div class="flex min-w-0 flex-col gap-[0.1875rem]">
                  <.link
                    navigate={~p"/servers/#{server}"}
                    class="truncate text-[0.9375rem] font-semibold after:absolute after:inset-0"
                  >
                    {server.name}
                  </.link>
                  <span class="truncate text-xs text-muted">
                    <.live_line live={@live[server.id]} server={server} />
                  </span>
                  <span class="flex items-center gap-2 text-xs lg:hidden">
                    <.stream_label status={@stream_status[server.id]} enabled={server.enabled} />
                  </span>
                </div>
              </div>

              <span class="hidden lg:block">
                <span class="rounded-full bg-secondary px-2.5 py-[0.3125rem] text-xs font-semibold text-subtle">
                  {game_short(server.game)}
                </span>
              </span>

              <span class="hidden truncate font-mono text-xs text-subtle lg:block">
                {server.base_url}
              </span>

              <span class="hidden flex-col gap-[0.1875rem] lg:flex">
                <span class="flex items-center gap-2 text-[0.8125rem]">
                  <.stream_label
                    status={@stream_status[server.id]}
                    enabled={server.enabled}
                    since={History.stream_down_since(server.id)}
                    id={"server-down-#{server.id}"}
                  />
                </span>
                <.stream_detail server={server} status={@stream_status[server.id]} />
              </span>

              <span class="hidden text-sm lg:block">
                {ngettext("%{count} active", "%{count} active", module_count(@modules, server),
                  count: module_count(@modules, server)
                )}
              </span>

              <span class="hidden truncate font-mono text-xs text-subtle lg:block">
                {server.timezone}
              </span>

              <div class="relative z-10 flex shrink-0 items-center justify-end">
                <.row_menu
                  :if={Accounts.can?(@current_user, :manage_servers)}
                  id={"server-menu-#{server.id}"}
                  label={gettext("More actions for %{name}", name: server.name)}
                >
                  <.menu_item icon="hero-pencil-square" patch={~p"/servers/#{server}/edit"}>
                    {gettext("Edit")}
                  </.menu_item>

                  <.menu_item
                    icon="hero-squares-plus"
                    navigate={~p"/servers/#{server}/marketplace"}
                  >
                    {gettext("Modules")}
                  </.menu_item>

                  <.menu_item icon="hero-power" phx-click="toggle" phx-value-id={server.id}>
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
              </div>
            </li>
          </ul>
        </section>

        <div class="grid gap-5 md:grid-cols-2">
          <section
            id="server-games"
            aria-label={gettext("Game profiles")}
            class="flex flex-col gap-2.5 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <.section_label>{gettext("Game profiles")}</.section_label>
            <div class="flex flex-wrap gap-2">
              <span
                :for={{game, count} <- games_in_use(@servers)}
                class="rounded-[0.875rem] bg-secondary px-3.5 py-2.5 text-sm"
              >
                {game_short(game)}
                <span class="text-muted">
                  · {if count == 0,
                    do: gettext("none yet"),
                    else: ngettext("%{count} server", "%{count} servers", count, count: count)}
                </span>
              </span>
            </div>
          </section>

          <section
            id="server-keys"
            aria-label={gettext("API keys")}
            class="flex flex-col gap-2.5 rounded-panel bg-base-100 p-[1.375rem]"
          >
            <.section_label>{gettext("API keys")}</.section_label>
            <p class="text-sm leading-normal text-subtle">
              {gettext(
                "Stored encrypted. Create a key in CRCON just for this tool, with the permissions the modules ask for."
              )}
            </p>
          </section>
        </div>
      </div>

      <.form_dialog
        :if={@live_action in [:new, :edit]}
        form={@form}
        server={@server}
        check={@check}
        stream_check={@stream_check}
        params={@form_params}
        modules={if @server.id, do: Map.get(@modules, @server.id, MapSet.new()), else: MapSet.new()}
        verified?={verified?(assigns)}
      />
    </Layouts.app>
    """
  end

  attr :live, :any, default: nil
  attr :server, :map, required: true

  # "Carentan · Guerra · 98/100", from the Briefing's cached live state.
  defp live_line(%{live: live} = assigns) when is_map(live) do
    ~H"""
    {Enum.join(
      Enum.reject([@live.map, @live.mode && LiveComponents.mode_label(@live.mode)], &is_nil/1),
      " · "
    )} · <span class="font-mono">{@live.players}/{@live.max_players || "–"}</span>
    """
  end

  defp live_line(assigns) do
    ~H"""
    {if @server.enabled, do: game_short(@server.game), else: gettext("Disabled")}
    """
  end

  attr :server, :map, required: true
  attr :status, :any, default: nil

  # The line under the stream's state: when the last event came, or since
  # when it is down.
  defp stream_detail(assigns) do
    assigns =
      assigns
      |> assign(:last_event, History.last_event_at(assigns.server.id))

    ~H"""
    <span :if={@server.enabled} class="truncate text-xs text-muted">
      <%= cond do %>
        <% match?({:error, _}, @status) -> %>
          {gettext("retrying")}
        <% @status == :connected and @last_event -> %>
          {gettext("last event")}
          <.local_time id={"server-last-event-#{@server.id}"} at={@last_event} format="relative" />
        <% true -> %>
      <% end %>
    </span>
    """
  end

  attr :status, :any, default: nil
  attr :enabled, :boolean, required: true
  attr :since, :any, default: nil
  attr :id, :string, default: nil

  defp stream_label(assigns) do
    ~H"""
    <span
      class={[
        "size-2 shrink-0 rounded-full",
        stream_dot(@status, @enabled),
        @enabled && @status == :connected &&
          "shadow-[0_0_0_3px_color-mix(in_oklab,var(--color-primary)_20%,transparent)]"
      ]}
      aria-hidden="true"
    ></span>
    <span class={["font-semibold", stream_text(@status, @enabled)]}>
      <%= if @enabled and @since && match?({:error, _}, @status) do %>
        {gettext("Down at")} <.clock id={@id} at={@since} class="font-mono" />
      <% else %>
        {if @enabled, do: Labels.stream_status(@status), else: gettext("Disabled")}
      <% end %>
    </span>
    """
  end

  defp stream_dot(_status, false), do: "bg-base-300"
  defp stream_dot(:connected, _enabled), do: "bg-primary"
  defp stream_dot(:connecting, _enabled), do: "bg-warning"
  defp stream_dot({:error, _reason}, _enabled), do: "bg-error"
  defp stream_dot(_status, _enabled), do: "bg-base-300"

  defp stream_text(_status, false), do: "text-muted"
  defp stream_text(:connected, _enabled), do: "text-primary"
  defp stream_text(:connecting, _enabled), do: "text-warning"
  defp stream_text({:error, _reason}, _enabled), do: "text-error"
  defp stream_text(_status, _enabled), do: "text-subtle"

  attr :form, :any, required: true
  attr :server, :any, required: true
  attr :check, :any, default: nil
  attr :stream_check, :any, default: nil
  attr :params, :map, default: %{}
  attr :modules, :any, required: true
  attr :verified?, :boolean, default: false

  defp form_dialog(assigns) do
    assigns =
      assigns
      |> assign(:tail, key_tail(assigns.params["api_key"]) || key_tail(assigns.server.api_key))
      |> assign(:zone, assigns.form[:timezone].value || "America/Sao_Paulo")

    ~H"""
    <.settings_dialog
      id="server-modal"
      icon="hero-server-stack"
      title={if @server.id, do: gettext("Edit server"), else: gettext("Add server")}
      subtitle={gettext("Fill it in, test the connection, and only then save.")}
      on_cancel={JS.patch(~p"/servers")}
    >
      <.form
        for={@form}
        id="server-form"
        phx-change="validate"
        phx-submit="save"
        class="settings-form grid h-full items-start gap-6 lg:grid-cols-[minmax(0,1fr)_26.25rem]"
      >
        <div class="flex flex-col gap-4">
          <div class="grid gap-3.5 sm:grid-cols-[minmax(0,1fr)_15.625rem]">
            <.input field={@form[:name]} type="text" label={gettext("Name")} no_margin required />
            <div class="flex flex-col gap-2">
              <span id="server-game-label" class="text-[0.8125rem] font-medium text-subtle">
                {gettext("Game")}
              </span>
              <div
                role="radiogroup"
                aria-labelledby="server-game-label"
                class="grid h-[2.875rem] grid-cols-2 gap-1 rounded-[0.875rem] border border-line-raised bg-secondary p-1"
              >
                <label :for={{label, value} <- Labels.game_options()} class="cursor-pointer">
                  <input
                    type="radio"
                    name={@form[:game].name}
                    value={value}
                    checked={to_string(@form[:game].value) == to_string(value)}
                    class="peer sr-only"
                  />
                  <span class="flex h-full items-center justify-center rounded-[0.625rem] text-[0.8125rem] text-subtle transition-colors peer-checked:bg-inverse peer-checked:font-semibold peer-checked:text-on-inverse peer-focus-visible:ring-2 peer-focus-visible:ring-primary/50">
                    {game_option_label(value, label)}
                  </span>
                </label>
              </div>
            </div>
          </div>

          <.input
            field={@form[:base_url]}
            type="url"
            label={gettext("CRCON address")}
            placeholder="https://crcon.example.com"
            class="font-mono text-[0.8125rem]"
            no_margin
            required
          />

          <div class="flex flex-col gap-2">
            <label for="server_api_key" class="text-[0.8125rem] font-medium text-subtle">
              {gettext("API key")}
            </label>
            <span class="flex h-[2.875rem] items-center rounded-[0.875rem] border border-line-raised bg-secondary pl-3.5 pr-1.5 focus-within:border-primary/60">
              <input
                type="password"
                id="server_api_key"
                name={@form[:api_key].name}
                value={@params["api_key"]}
                autocomplete="off"
                placeholder={if @server.id, do: gettext("Leave blank to keep the current key")}
                class="min-w-0 flex-1 border-0 bg-transparent p-0 font-mono text-[0.8125rem] tracking-[0.1em] outline-none placeholder:tracking-normal placeholder:text-muted focus:ring-0"
              />
              <span :if={@tail} id="server-key-tail" class="mr-1.5 font-mono text-xs text-muted">
                {gettext("ends in %{tail}", tail: @tail)}
              </span>
              <button
                type="button"
                id="server-key-reveal"
                aria-label={gettext("Show key")}
                phx-click={JS.toggle_attribute({"type", "text", "password"}, to: "#server_api_key")}
                class="flex size-9 items-center justify-center rounded-[0.625rem] text-muted hover:text-base-content"
              >
                <.icon name="hero-eye" class="size-4" />
              </button>
            </span>
            <span class="text-xs text-muted">
              {gettext("Stored encrypted. After saving, only the end is shown.")}
            </span>
            <p
              :for={msg <- Enum.map(@form[:api_key].errors, &translate_error/1)}
              class="pc-form-field-error"
            >
              {msg}
            </p>
          </div>

          <div class="flex flex-col gap-2">
            <label for="server_timezone" class="text-[0.8125rem] font-medium text-subtle">
              {gettext("Time zone")}
            </label>
            <span class="relative flex h-[2.875rem] items-center gap-2.5 rounded-[0.875rem] border border-line-raised bg-secondary px-3.5 focus-within:border-primary/60">
              <span class="font-mono text-[0.8125rem]">{@zone}</span>
              <span class="min-w-0 flex-1 truncate text-[0.8125rem] text-muted">
                {[
                  utc_offset(@zone),
                  gettext("schedules and “Periodically” use this zone")
                ]
                |> Enum.reject(&is_nil/1)
                |> Enum.join(" · ")}
              </span>
              <.icon name="hero-chevron-down" class="size-4 shrink-0 text-muted" />
              <select
                id="server_timezone"
                name={@form[:timezone].name}
                class="absolute inset-0 size-full cursor-pointer opacity-0"
              >
                {Phoenix.HTML.Form.options_for_select(
                  Server.timezone_options(@server),
                  @form[:timezone].value
                )}
              </select>
            </span>
          </div>

          <div class="flex flex-col gap-2">
            <label for="server_notes" class="text-[0.8125rem] font-medium text-subtle">
              {gettext("Notes")}
              <span class="font-normal text-muted">· {gettext("only the staff sees them")}</span>
            </label>
            <textarea
              id="server_notes"
              name={@form[:notes].name}
              rows="3"
              class="pc-text-input resize-none leading-normal"
            >{Phoenix.HTML.Form.normalize_value("textarea", @form[:notes].value)}</textarea>
          </div>

          <.switch_row
            field={@form[:log_stream_enabled]}
            label={gettext("Consume the live log stream")}
            hint={
              gettext(
                "Kills, chat and connections arrive in real time. Without it, only “Periodically” and match start and end fire."
              )
            }
          />
          <.switch_row
            :if={@server.id}
            field={@form[:enabled]}
            label={gettext("Enabled")}
            hint={gettext("A disabled server is ignored by the engine.")}
          />
        </div>

        <section
          id="server-check"
          aria-label={gettext("Test connection")}
          class="flex min-h-full flex-col gap-3.5 rounded-[1.375rem] border border-line-raised bg-secondary p-[1.125rem]"
        >
          <div class="flex items-center gap-2.5">
            <div class="flex min-w-0 flex-1 flex-col gap-0.5">
              <h3 class="font-display text-lg font-semibold">{gettext("Test connection")}</h3>
              <p class="text-xs text-muted">
                <%= case @check do %>
                  <% {:ok, result} -> %>
                    {gettext("Tested at")}
                    <.clock
                      id="server-tested-at"
                      at={result.tested_at}
                      class="font-mono"
                    /> {gettext("with the key above")}
                  <% _other -> %>
                    {gettext("Not tested yet")}
                <% end %>
              </p>
            </div>
            <button
              id="server-check-button"
              type="button"
              phx-click="check_connection"
              phx-disable-with={gettext("Testing…")}
              class="flex h-9 shrink-0 items-center gap-1.5 rounded-full border border-line-strong bg-base-100 px-3.5 text-[0.8125rem] transition-colors hover:bg-base-300"
            >
              <.icon name="hero-arrow-path" class="size-3.5" />
              {if @check, do: gettext("Test again"), else: gettext("Test connection")}
            </button>
          </div>

          <.check_result check={@check} stream_check={@stream_check} modules={@modules} />
        </section>
      </.form>

      <:footer>
        <p class="flex min-w-0 flex-1 items-center gap-2 text-[0.8125rem] text-subtle">
          <.icon
            name={if @verified?, do: "hero-check", else: "hero-lock-closed"}
            class={["size-4 shrink-0", if(@verified?, do: "text-primary", else: "text-muted")]}
          />
          {if @verified?,
            do:
              gettext(
                "The connection passed the test, so it can be saved. Permissions can be adjusted later."
              ),
            else: gettext("Saving unlocks once the connection test passes.")}
        </p>
        <.link
          patch={~p"/servers"}
          class="flex h-12 items-center rounded-full border border-base-300 bg-secondary px-5 text-sm transition-colors hover:bg-base-300"
        >
          {gettext("Cancel")}
        </.link>
        <button
          type="submit"
          form="server-form"
          disabled={not @verified?}
          phx-disable-with={gettext("Saving...")}
          class="flex h-12 items-center rounded-full bg-[var(--tone-cta)] px-6 text-sm font-semibold text-[var(--tone-on-cta)] transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40"
        >
          {gettext("Save server")}
        </button>
      </:footer>
    </.settings_dialog>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp switch_row(assigns) do
    assigns =
      assign(
        assigns,
        :checked,
        Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value)
      )

    ~H"""
    <label
      for={@field.id}
      class="flex cursor-pointer items-center gap-3.5 rounded-2xl border border-line-raised bg-secondary px-4 py-3.5"
    >
      <span class="flex min-w-0 flex-1 flex-col gap-[0.1875rem]">
        <span class="text-sm font-semibold">{@label}</span>
        <span :if={@hint} class="text-xs leading-[1.45] text-muted">{@hint}</span>
      </span>
      <input type="hidden" name={@field.name} value="false" />
      <.switch id={@field.id} name={@field.name} checked={@checked} size="lg" />
    </label>
    """
  end

  attr :check, :any, default: nil
  attr :stream_check, :any, default: nil
  attr :modules, :any, required: true

  defp check_result(%{check: nil} = assigns) do
    ~H"""
    <p class="rounded-xl bg-base-100 p-4 text-[0.8125rem] leading-normal text-subtle">
      {gettext(
        "The test connects with the address and key, reads who the key belongs to and reviews its permissions."
      )}
    </p>
    """
  end

  defp check_result(%{check: {:error, _message}} = assigns) do
    assigns = assign(assigns, :message, elem(assigns.check, 1))

    ~H"""
    <div
      id="server-check-result"
      class="flex items-start gap-2.5 rounded-2xl border border-error/30 bg-error/8 p-4 text-[0.8125rem]"
    >
      <.icon name="hero-x-circle" class="mt-0.5 size-4 shrink-0 text-error" />
      <span>{@message}</span>
    </div>
    """
  end

  defp check_result(%{check: {:ok, _result}} = assigns) do
    result = elem(assigns.check, 1)
    review = result.info.permissions

    assigns =
      assigns
      |> assign(:result, result)
      |> assign(:review, review)
      |> assign(:sorted, ConnectionTest.review(review, assigns.modules))

    ~H"""
    <div id="server-check-result" class="flex flex-col gap-3.5">
      <ul class="flex flex-col gap-1.5">
        <.check_row ok>
          {gettext("Connected")}
          <:aside>
            <span class="font-mono text-xs text-primary">{@result.latency_ms} ms</span>
          </:aside>
        </.check_row>
        <.check_row ok={is_binary(@result.version)}>
          {gettext("CRCON version")}
          <:aside>
            <span class="font-mono text-xs text-subtle">
              {@result.version || gettext("not reported")}
            </span>
          </:aside>
        </.check_row>
        <%= case @stream_check do %>
          <% {:ok, events} -> %>
            <.check_row ok>
              {gettext("The log stream answered")}
              <:aside>
                <span class="font-mono text-xs text-subtle">
                  {ngettext("%{count} event", "%{count} events", events, count: events)}
                </span>
              </:aside>
            </.check_row>
          <% {:error, reason} -> %>
            <.check_row ok={false}>
              {gettext("The log stream did not answer")}
              <:aside>
                <span class="max-w-40 truncate font-mono text-xs text-error" title={reason}>
                  {reason}
                </span>
              </:aside>
            </.check_row>
          <% _pending -> %>
            <.check_row pending>
              {gettext("Opening the log stream…")}
            </.check_row>
        <% end %>
      </ul>

      <div class="flex items-baseline gap-2 pt-1">
        <strong class="flex-1 text-sm font-semibold">{gettext("Key permissions")}</strong>
        <span class="text-xs text-muted">
          {gettext("%{fine} right · %{review} to review",
            fine: @sorted.fine,
            review: @sorted.to_review
          )}
        </span>
      </div>

      <p
        :if={@review.superuser?}
        class="rounded-2xl border border-error/30 bg-error/8 p-4 text-[0.8125rem]"
      >
        {gettext(
          "This key belongs to a CRCON superuser, which bypasses every permission check. Create a regular user holding only the permissions it needs and issue a key for it."
        )}
      </p>

      <div
        :if={@sorted.missing != []}
        id="server-check-missing"
        class="flex flex-col gap-2 rounded-2xl border border-warning/30 bg-warning/8 px-3.5 py-3"
      >
        <span class="flex items-center gap-2 text-[0.8125rem] font-semibold text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {gettext("Missing %{count}", count: length(@sorted.missing))}
        </span>
        <div :for={{permission, need} <- @sorted.missing} class="flex items-center gap-2">
          <span class="min-w-0 flex-1 truncate font-mono text-xs">{permission}</span>
          <span class="rounded-full bg-warning/14 px-2 py-[0.1875rem] text-[0.6875rem] font-semibold text-warning">
            {need_label(need)}
          </span>
        </div>
        <span class="text-xs leading-[1.45] text-subtle">
          {missing_note(@sorted.missing)}
        </span>
      </div>

      <div
        :if={@sorted.excess != []}
        id="server-check-excess"
        class="flex flex-col gap-2 rounded-2xl border border-error/30 bg-error/8 px-3.5 py-3"
      >
        <span class="flex items-center gap-2 text-[0.8125rem] font-semibold text-error">
          <.icon name="hero-shield-exclamation" class="size-4" />
          {gettext("Extra %{count}", count: length(@sorted.excess))}
        </span>
        <span :for={permission <- @sorted.excess} class="font-mono text-xs">{permission}</span>
        <span class="text-xs leading-[1.45] text-subtle">
          {gettext(
            "The key can do more than it needs. No module uses this; remove it in CRCON to reduce the risk. Until then the server cannot be saved."
          )}
        </span>
      </div>
    </div>
    """
  end

  defp need_label(:vip_shop), do: gettext("VIP shop")
  defp need_label(_rules), do: gettext("Rules")

  defp missing_note(missing) do
    if Enum.any?(missing, &(elem(&1, 1) == :vip_shop)),
      do: gettext("Without them, the VIP shop cannot grant VIP on this server."),
      else:
        gettext(
          "Without them, the rules that read this information never match: CRCON answers 403 where nobody is looking."
        )
  end

  attr :ok, :boolean, default: false
  attr :pending, :boolean, default: false
  slot :inner_block, required: true
  slot :aside

  defp check_row(assigns) do
    ~H"""
    <li class="flex items-center gap-2.5 rounded-xl bg-base-100 px-3 py-2.5 text-[0.8125rem]">
      <span class={[
        "flex size-[1.375rem] shrink-0 items-center justify-center rounded-full",
        cond do
          @pending -> "bg-secondary text-muted"
          @ok -> "bg-primary/14 text-primary"
          true -> "bg-error/14 text-error"
        end
      ]}>
        <.icon
          name={
            cond do
              @pending -> "hero-arrow-path"
              @ok -> "hero-check"
              true -> "hero-x-mark"
            end
          }
          class={["size-3.5", @pending && "animate-spin"]}
        />
      </span>
      <span class="min-w-0 flex-1">{render_slot(@inner_block)}</span>
      {render_slot(@aside)}
    </li>
    """
  end
end
