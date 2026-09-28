defmodule HllConditionalActionsWeb.TicketLive.Settings do
  @moduledoc """
  A server's ticket settings: on or off, the chat commands that open a
  ticket, the waiting time between tickets, when silent tickets close, and
  what the player is told.

  The form is cut into sections (`HllConditionalActionsWeb.TicketSettingsForm`)
  shown one at a time behind a side menu, and saved together. A first-time
  setup is easier through the wizard (`HllConditionalActionsWeb.TicketLive.Setup`).

  Under `/servers/:server_id/tickets/settings` it edits that server. Under
  `/tickets/settings` the admin ticks one or more of their servers and the
  same settings are saved to each; ticking a single server loads what it has
  now, so the page also works as "copy this server's settings to others".
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_tickets}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Discord
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActionsWeb.TicketSettingsForm

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, server} <- Servers.fetch_server(server_id),
         true <- Accounts.can_access_server?(user, server) do
      settings = Tickets.get_settings(server.id)

      {:ok,
       socket
       |> assign(:page_title, gettext("Ticket settings"))
       |> assign(:section, :general)
       |> assign(:server, server)
       |> assign(:servers, [])
       |> assign(:selected, [server.id])
       |> assign(:webhooks, Discord.list_webhooks())
       |> assign(:settings, with_defaults(settings))
       |> assign_form(Tickets.change_settings(with_defaults(settings)))}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not have access to that page."))
         |> push_navigate(to: ~p"/tickets")}
    end
  end

  # No server in the URL: pick the servers on the page.
  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, gettext("Ticket settings"))
     |> assign(:section, :general)
     |> assign(:server, nil)
     |> assign(:servers, servers)
     |> assign(:webhooks, Discord.list_webhooks())
     |> assign(:statuses, statuses(servers))
     |> select(Enum.take(Enum.map(servers, & &1.id), 1))}
  end

  defp statuses(servers), do: Map.new(servers, &{&1.id, Tickets.get_settings(&1.id)})

  # One server ticked: show what it has. Several: keep what is on the form,
  # since that is what will be written to all of them.
  defp select(socket, [id]) do
    settings = with_defaults(Tickets.get_settings(id))

    socket
    |> assign(:selected, [id])
    |> assign(:settings, settings)
    |> assign_form(Tickets.change_settings(settings))
  end

  defp select(socket, ids) do
    socket = assign(socket, :selected, ids)

    if socket.assigns[:form] do
      socket
    else
      settings = with_defaults(%HllConditionalActions.Tickets.Settings{})

      socket
      |> assign(:settings, settings)
      |> assign_form(Tickets.change_settings(settings))
    end
  end

  defp with_defaults(settings), do: TicketSettingsForm.defaults(settings)

  @impl Phoenix.LiveView
  def handle_event("validate", %{"settings" => params}, socket) do
    changeset =
      socket.assigns.settings
      |> Tickets.change_settings(parse(params))
      |> Map.put(:action, :validate)

    # Rows are kept as typed, blank ones included, until saved.
    {:noreply, socket |> assign_form(changeset) |> assign(:category_rows, rows(params))}
  end

  def handle_event("section", %{"section" => section}, socket) do
    section = Enum.find(TicketSettingsForm.sections(), :general, &(to_string(&1) == section))
    {:noreply, assign(socket, :section, section)}
  end

  def handle_event("add_category", _params, socket) do
    rows = socket.assigns.category_rows ++ [%{"name" => "", "priority" => "normal"}]
    {:noreply, assign(socket, :category_rows, rows)}
  end

  def handle_event("remove_category", %{"index" => index}, socket) do
    rows = List.delete_at(socket.assigns.category_rows, String.to_integer(index))
    {:noreply, assign(socket, :category_rows, rows)}
  end

  def handle_event("select_servers", params, socket) do
    allowed = MapSet.new(socket.assigns.servers, & &1.id)

    ids =
      params
      |> Map.get("server_ids", [])
      |> Enum.flat_map(&parse_id/1)
      |> Enum.filter(&MapSet.member?(allowed, &1))

    {:noreply, select(socket, ids)}
  end

  def handle_event("save", %{"settings" => _params}, %{assigns: %{selected: []}} = socket),
    do: {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

  def handle_event("save", %{"settings" => params}, %{assigns: %{server: nil}} = socket) do
    params = parse(params)
    changeset = Tickets.change_settings(socket.assigns.settings, params)

    if changeset.valid? do
      Enum.each(socket.assigns.selected, fn id ->
        {:ok, _saved} = Tickets.save_settings(Tickets.get_settings(id), params)
      end)

      {:noreply,
       socket
       |> assign(:statuses, statuses(socket.assigns.servers))
       |> put_flash(
         :info,
         ngettext(
           "Ticket settings saved on 1 server.",
           "Ticket settings saved on %{count} servers.",
           length(socket.assigns.selected)
         )
       )}
    else
      {:noreply, socket |> assign_form(Map.put(changeset, :action, :validate)) |> open_error()}
    end
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Tickets.save_settings(socket.assigns.settings, parse(params)) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign_form(Tickets.change_settings(settings))
         |> put_flash(:info, gettext("Ticket settings saved."))}

      {:error, changeset} ->
        {:noreply, socket |> assign_form(changeset) |> open_error()}
    end
  end

  defp open_error(socket) do
    case Enum.find(
           TicketSettingsForm.sections(),
           &(TicketSettingsForm.error_count(socket.assigns.form, &1) > 0)
         ) do
      nil -> socket
      section -> assign(socket, :section, section)
    end
  end

  defp parse_id(id), do: TicketSettingsForm.parse_id(id)
  defp parse(params), do: TicketSettingsForm.parse(params)
  defp rows(params), do: TicketSettingsForm.rows(params)
  defp assign_form(socket, changeset), do: TicketSettingsForm.assign_form(socket, changeset)

  @doc """
  Splits the commands line into a list.

      iex> HllConditionalActionsWeb.TicketLive.Settings.split_commands("!admin, !adm  @help")
      ["!admin", "!adm", "@help"]
  """
  @spec split_commands(String.t() | nil) :: [String.t()]
  defdelegate split_commands(text), to: TicketSettingsForm

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={if @server, do: @server.name, else: gettext("One or more servers")}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={if @server, do: ~p"/servers/#{@server.id}/tickets/setup", else: ~p"/tickets/setup"}
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-sparkles"
          label={gettext("Setup wizard")}
        />
        <.button
          link_type="live_redirect"
          to={if @server, do: ~p"/servers/#{@server.id}/tickets", else: ~p"/tickets"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
          label={gettext("Tickets")}
        />
      </:actions>

      <.card
        :if={is_nil(@server)}
        title={gettext("Servers to configure")}
        icon="hero-server-stack"
        id="ticket-settings-servers"
      >
        <p :if={@servers == []} class="text-sm text-muted">
          {gettext("You have no server yet.")}
        </p>
        <form
          :if={@servers != []}
          id="server-picker"
          phx-change="select_servers"
          class="grid gap-2 sm:grid-cols-2"
        >
          <input type="hidden" name="server_ids[]" value="" />
          <label
            :for={server <- @servers}
            class="flex cursor-pointer items-center justify-between gap-3 rounded-field border border-base-300 px-3 py-2 transition-colors hover:bg-base-200/60 has-[:checked]:border-primary/50 has-[:checked]:bg-primary/5"
          >
            <span class="flex min-w-0 items-center gap-2">
              <input
                type="checkbox"
                name="server_ids[]"
                value={server.id}
                checked={server.id in @selected}
                class="pc-checkbox"
              />
              <span class="truncate font-medium">{server.name}</span>
            </span>
            <.tone_badge :if={@statuses[server.id].enabled} tone="success">
              {gettext("On")} · {Enum.join(@statuses[server.id].commands, " ")}
            </.tone_badge>
            <.tone_badge :if={!@statuses[server.id].enabled} tone="neutral">
              {gettext("Off")}
            </.tone_badge>
          </label>
        </form>
        <p :if={length(@selected) > 1} class="text-sm text-muted" id="multi-save-note">
          {gettext(
            "Saving writes these settings to every server ticked above, replacing what they have."
          )}
        </p>
      </.card>

      <.form
        for={@form}
        id="ticket-settings-form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-4 lg:grid-cols-[14rem_1fr]"
      >
        <aside class="lg:sticky lg:top-20 lg:self-start">
          <TicketSettingsForm.section_nav current={@section} form={@form} />
        </aside>

        <div class="min-w-0 space-y-4">
          <.card>
            <TicketSettingsForm.section
              :for={name <- TicketSettingsForm.sections()}
              name={name}
              visible={name == @section}
              form={@form}
              commands={@commands}
              commands_text={@commands_text}
              quick_replies_text={@quick_replies_text}
              category_rows={@category_rows}
              hours_days={@hours_days}
              webhooks={@webhooks}
              admin_name={@current_user.name || @current_user.username}
              multi?={length(@selected) > 1}
            />
          </.card>

          <div
            id="settings-save-bar"
            class="sticky bottom-3 z-10 flex flex-wrap items-center justify-between gap-3 rounded-box border border-base-300 bg-base-100/95 px-4 py-3 shadow-figma-card backdrop-blur"
          >
            <p class="text-sm text-muted">
              <span :if={@form.source.changes != %{}} class="font-medium text-warning" id="unsaved">
                <.icon name="hero-pencil-square" class="size-4" />
                {gettext("Unsaved changes")}
              </span>
              <span :if={@form.source.changes == %{}}>
                {gettext("Every section is saved together.")}
              </span>
            </p>
            <.button
              type="submit"
              size="sm"
              color="primary"
              icon="hero-check"
              phx-disable-with={gettext("Saving...")}
              label={gettext("Save")}
            />
          </div>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
