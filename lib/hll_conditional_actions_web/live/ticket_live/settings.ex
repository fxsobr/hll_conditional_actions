defmodule HllConditionalActionsWeb.TicketLive.Settings do
  @moduledoc """
  A server's ticket settings, in three columns: the categories (colour,
  priority, how many tickets each got this month), closing silent tickets
  and the Discord alert; the quick replies (with how often each is used)
  and the messages the player reads in game; the office hours, a bar per
  weekday with as many ranges as needed, and what happens outside them.

  Everything is saved together from the header, which counts the unsaved
  changes. The commands, the waiting time and who may open a ticket are set
  in the wizard (`HllConditionalActionsWeb.TicketLive.Setup`); the few
  settings no board shows (alert time, hourly limit, default priority, the
  player's words) sit folded under "More settings".

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
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActions.Tickets.Stats
  alias HllConditionalActionsWeb.TicketComponents
  alias HllConditionalActionsWeb.TicketSettingsForm

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, server} <- Servers.fetch_server(server_id),
         true <- Accounts.can_access_server?(user, server) do
      {:ok,
       socket
       |> base_assigns()
       |> assign(:server, server)
       |> assign(:servers, [server])
       |> assign(:statuses, statuses([server]))
       |> select([server.id])}
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
     |> base_assigns()
     |> assign(:server, nil)
     |> assign(:servers, servers)
     |> assign(:statuses, statuses(servers))
     |> select(Enum.take(Enum.map(servers, & &1.id), 1))}
  end

  defp base_assigns(socket) do
    socket
    |> assign(:page_title, gettext("Inbox"))
    |> assign(:webhooks, Discord.list_webhooks())
    |> assign(:selected, [])
    |> assign(:params, %{})
    |> assign(:editing_category, nil)
    |> assign(:editing_reply, nil)
    |> assign(:open_message, "received")
    |> assign(:editing_day, nil)
  end

  defp statuses(servers), do: Map.new(servers, &{&1.id, Tickets.get_settings(&1.id)})

  # One server ticked: show what it has. Several: keep what is on the form,
  # since that is what will be written to all of them.
  defp select(socket, [id]) do
    settings = with_defaults(Tickets.get_settings(id))

    socket
    |> assign(:selected, [id])
    |> load_settings(settings)
  end

  defp select(socket, ids) do
    socket = assign(socket, :selected, ids)

    if socket.assigns[:settings],
      do: build(socket),
      else: load_settings(socket, with_defaults(%Settings{}))
  end

  defp load_settings(socket, settings) do
    rows = TicketSettingsForm.rows(settings)

    socket
    |> assign(:settings, settings)
    |> assign(:params, %{})
    |> assign(:rows, rows)
    |> assign(:initial_rows, rows)
    |> assign(:editing_category, nil)
    |> assign(:editing_reply, nil)
    |> assign(:editing_day, nil)
    |> load_counts()
    |> build()
  end

  defp with_defaults(settings), do: TicketSettingsForm.defaults(settings)

  # The numbers beside the rows, for the (first) server on the form.
  defp load_counts(socket) do
    server = first_server(socket)

    if server do
      socket
      |> assign(:category_counts, Stats.category_counts_this_month(server.id, server.timezone))
      |> assign(:reply_uses, Stats.reply_uses(server.id))
      |> assign(:last_announcement, Stats.last_announcement(server.id))
    else
      socket
      |> assign(:category_counts, %{})
      |> assign(:reply_uses, %{})
      |> assign(:last_announcement, nil)
    end
  end

  defp first_server(%{assigns: %{servers: servers, selected: [id | _rest]}}),
    do: Enum.find(servers, &(&1.id == id))

  defp first_server(_socket), do: nil

  # The changeset from the fields as typed and the rows as they stand.
  defp build(socket, action \\ nil) do
    %{settings: settings, params: params, rows: rows} = socket.assigns

    changeset =
      settings
      |> Tickets.change_settings(attrs(params, rows))
      |> Map.put(:action, action)

    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :settings))
    |> assign(:dirty, dirty(changeset, rows, socket.assigns.initial_rows))
  end

  defp attrs(params, rows) do
    params
    |> TicketSettingsForm.parse()
    |> Map.merge(%{
      "category_priorities" => Map.new(rows.categories, &{&1["name"], &1["priority"]}),
      "category_colors" => Map.new(rows.categories, &{&1["name"], &1["color"]}),
      "category_order" => Enum.map(rows.categories, & &1["name"]),
      "replies" => rows.replies,
      "quick_replies" => Enum.map(rows.replies, & &1["body"]),
      "hours_ranges" => rows.hours
    })
  end

  # What changed since the page loaded: the rows by value, other fields by
  # the changeset.
  defp dirty(changeset, rows, initial) do
    fields =
      changeset
      |> TicketSettingsForm.changed_groups()
      |> Enum.reject(&(&1 in [:categories, :replies, :hours]))

    rows_changed =
      for group <- [:categories, :replies, :hours],
          Map.get(rows, group) != Map.get(initial, group),
          do: group

    length(fields) + length(rows_changed)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("validate", %{"settings" => params}, socket) do
    rows = socket.assigns.rows

    rows = %{
      rows
      | categories:
          if(Map.has_key?(params, "categories"),
            do: TicketSettingsForm.category_rows(params),
            else: rows.categories
          ),
        replies:
          if(Map.has_key?(params, "replies"),
            do: TicketSettingsForm.reply_rows(params),
            else: rows.replies
          ),
        hours:
          if(Map.has_key?(params, "hours"),
            do: TicketSettingsForm.hour_rows(params),
            else: rows.hours
          )
    }

    fields = Map.drop(params, ["categories", "replies", "hours"])

    {:noreply,
     socket
     |> assign(:params, Map.merge(socket.assigns.params, fields))
     |> assign(:rows, rows)
     |> build(socket.assigns.changeset.action)}
  end

  def handle_event("discard", _params, %{assigns: %{server: nil}} = socket),
    do: {:noreply, select(socket, socket.assigns.selected) |> reload_selected()}

  def handle_event("discard", _params, socket),
    do:
      {:noreply,
       load_settings(socket, with_defaults(Tickets.get_settings(socket.assigns.server.id)))}

  def handle_event("add_category", _params, socket) do
    categories = socket.assigns.rows.categories
    color = Settings.color_for(nil, length(categories))
    row = %{"name" => "", "priority" => "normal", "color" => color}

    {:noreply,
     socket
     |> update_rows(:categories, categories ++ [row])
     |> assign(:editing_category, length(categories))}
  end

  def handle_event("edit_category", %{"index" => index}, socket) do
    index = parse_index(index)
    index = if index == socket.assigns.editing_category, do: nil, else: index
    {:noreply, assign(socket, :editing_category, index)}
  end

  def handle_event("remove_category", %{"index" => index}, socket) do
    categories = List.delete_at(socket.assigns.rows.categories, parse_index(index))
    {:noreply, socket |> update_rows(:categories, categories) |> assign(:editing_category, nil)}
  end

  def handle_event("reorder_categories", %{"order" => order}, socket),
    do: {:noreply, reorder(socket, :categories, order, :editing_category)}

  def handle_event("add_reply", _params, socket) do
    replies = socket.assigns.rows.replies
    row = %{"title" => "", "body" => "", "closes" => false}

    {:noreply,
     socket
     |> update_rows(:replies, replies ++ [row])
     |> assign(:editing_reply, length(replies))}
  end

  def handle_event("edit_reply", %{"index" => index}, socket),
    do: {:noreply, assign(socket, :editing_reply, parse_index(index))}

  def handle_event("remove_reply", %{"index" => index}, socket) do
    replies = List.delete_at(socket.assigns.rows.replies, parse_index(index))
    {:noreply, socket |> update_rows(:replies, replies) |> assign(:editing_reply, nil)}
  end

  def handle_event("reorder_replies", %{"order" => order}, socket),
    do: {:noreply, reorder(socket, :replies, order, :editing_reply)}

  def handle_event("open_message", %{"key" => key}, socket)
      when key in ~w(received reply closed),
      do: {:noreply, assign(socket, :open_message, key)}

  def handle_event("edit_day", %{"day" => day}, socket) do
    day = if day == socket.assigns.editing_day, do: nil, else: day
    {:noreply, assign(socket, :editing_day, day)}
  end

  # A new range on the day being edited (Monday when none is), after its
  # last one.
  def handle_event("add_range", _params, socket) do
    day = socket.assigns.editing_day || "1"
    hours = socket.assigns.rows.hours
    ranges = Map.get(hours, day, [])
    range = if ranges == [], do: ["18:00", "24:00"], else: ["12:00", "14:00"]

    {:noreply,
     socket
     |> update_rows(:hours, Map.put(hours, day, ranges ++ [range]))
     |> assign(:editing_day, day)}
  end

  def handle_event("remove_range", %{"day" => day, "index" => index}, socket) do
    hours = socket.assigns.rows.hours
    ranges = hours |> Map.get(day, []) |> List.delete_at(parse_index(index))
    {:noreply, update_rows(socket, :hours, Map.put(hours, day, ranges))}
  end

  def handle_event("select_servers", params, socket) do
    allowed = MapSet.new(socket.assigns.servers, & &1.id)

    ids =
      params
      |> Map.get("server_ids", [])
      |> Enum.flat_map(&TicketSettingsForm.parse_id/1)
      |> Enum.filter(&MapSet.member?(allowed, &1))

    {:noreply, select(socket, ids)}
  end

  def handle_event("save", _params, %{assigns: %{selected: []}} = socket),
    do: {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

  def handle_event("save", params, socket) do
    # The submit carries the whole form; fold it in like a change first.
    {:noreply, socket} =
      case params do
        %{"settings" => settings} -> handle_event("validate", %{"settings" => settings}, socket)
        _none -> {:noreply, socket}
      end

    %{params: params, rows: rows, selected: selected} = socket.assigns
    attrs = attrs(params, rows)

    if socket.assigns.changeset.valid? do
      Enum.each(selected, fn id ->
        {:ok, _saved} = Tickets.save_settings(Tickets.get_settings(id), attrs)
      end)

      {:noreply,
       socket
       |> assign(:statuses, statuses(socket.assigns.servers))
       |> put_flash(
         :info,
         ngettext(
           "Ticket settings saved.",
           "Ticket settings saved on %{count} servers.",
           length(selected)
         )
       )
       |> load_settings(with_defaults(Tickets.get_settings(hd(selected))))}
    else
      {:noreply, build(socket, :validate)}
    end
  end

  defp reload_selected(socket), do: assign(socket, :statuses, statuses(socket.assigns.servers))

  defp update_rows(socket, group, value) do
    socket
    |> assign(:rows, Map.put(socket.assigns.rows, group, value))
    |> build(socket.assigns.changeset.action)
  end

  defp reorder(socket, group, order, editing_key) do
    rows = Map.fetch!(socket.assigns.rows, group)
    indexes = Enum.map(order, &parse_index/1)

    if Enum.sort(indexes) == Enum.to_list(0..(length(rows) - 1)//1) do
      socket
      |> update_rows(group, Enum.map(indexes, &Enum.at(rows, &1)))
      |> assign(editing_key, nil)
    else
      socket
    end
  end

  defp parse_index(index) do
    case Integer.parse(to_string(index)) do
      {index, ""} -> index
      _other -> nil
    end
  end

  @doc """
  Splits the commands line into a list.

      iex> HllConditionalActionsWeb.TicketLive.Settings.split_commands("!admin, !adm  @help")
      ["!admin", "!adm", "@help"]
  """
  @spec split_commands(String.t() | nil) :: [String.t()]
  defdelegate split_commands(text), to: TicketSettingsForm

  # ── Render helpers ─────────────────────────────────────────────────────────

  defp applied(changeset), do: Ecto.Changeset.apply_changes(changeset)

  defp webhook_state(nil), do: :none

  defp webhook_state(webhook) do
    cond do
      webhook.last_error_at &&
          (is_nil(webhook.last_delivered_at) or
             DateTime.compare(webhook.last_error_at, webhook.last_delivered_at) == :gt) ->
        :error

      webhook.last_delivered_at ->
        :ok

      true ->
        :untested
    end
  end

  defp field_value(form, field) do
    case form[field].value do
      value when value in [true, "true"] -> true
      _other -> false
    end
  end

  defp now_marker(server) do
    zone = (server && server.timezone) || "Etc/UTC"

    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, local} -> {Date.day_of_week(local), local.hour * 60 + local.minute}
      _error -> nil
    end
  end

  defp servers_label(servers, selected) do
    case Enum.filter(servers, &(&1.id in selected)) do
      [] -> gettext("No server")
      [server] -> server.name
      [one, two] -> gettext("%{one} and %{two}", one: one.name, two: two.name)
      several -> ngettext("1 server", "%{count} servers", length(several))
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    server = first_server(%{assigns: assigns})
    current = applied(assigns.changeset)
    webhook = Enum.find(assigns.webhooks, &(&1.id == current.discord_webhook_id))

    assigns =
      assigns
      |> assign(:first, server)
      |> assign(:current, current)
      |> assign(:webhook, webhook)
      |> assign(
        :open_now?,
        Tickets.in_hours?(current, server && server.timezone, DateTime.utc_now())
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <details :if={is_nil(@server)} id="settings-servers" class="relative">
          <summary class="flex h-12 cursor-pointer list-none items-center gap-2.5 rounded-full border border-base-300 bg-base-100 pl-1.5 pr-4 text-sm font-medium [&::-webkit-details-marker]:hidden">
            <span class="flex size-9 items-center justify-center rounded-full bg-secondary text-[0.8125rem] font-bold">
              {length(@selected)}
            </span>
            {servers_label(@servers, @selected)}
            <.icon name="hero-chevron-down" class="size-4 text-muted" />
          </summary>
          <form
            id="server-picker"
            phx-change="select_servers"
            class="absolute right-0 top-full z-30 mt-2 flex w-72 flex-col gap-1 rounded-2xl border border-base-300 bg-base-100 p-2 shadow-lg"
          >
            <input type="hidden" name="server_ids[]" value="" />
            <p :if={@servers == []} class="p-2 text-sm text-muted">
              {gettext("You have no server yet.")}
            </p>
            <label
              :for={server <- @servers}
              class="flex cursor-pointer items-center justify-between gap-3 rounded-xl px-2.5 py-2 hover:bg-secondary"
            >
              <span class="flex min-w-0 items-center gap-2.5">
                <input
                  type="checkbox"
                  name="server_ids[]"
                  value={server.id}
                  checked={server.id in @selected}
                  class="size-4 accent-[var(--color-primary)]"
                />
                <span class="truncate text-sm">{server.name}</span>
              </span>
              <span class={[
                "text-[0.6875rem] font-semibold",
                if(@statuses[server.id].enabled, do: "text-primary", else: "text-muted")
              ]}>
                {if @statuses[server.id].enabled, do: gettext("On"), else: gettext("Off")}
              </span>
            </label>
            <p
              :if={length(@selected) > 1}
              class="px-2.5 pb-1 pt-2 text-xs text-warning"
              id="multi-save-note"
            >
              {gettext(
                "Saving writes these settings to every server ticked, replacing what they have."
              )}
            </p>
          </form>
        </details>

        <label class="flex h-12 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 pl-3 pr-4 text-sm">
          <TicketSettingsForm.switch
            name="settings[enabled]"
            id="settings_enabled"
            form="ticket-settings-form"
            checked={field_value(@form, :enabled)}
            label={gettext("Tickets on")}
          />
          <span class="whitespace-nowrap">
            {if field_value(@form, :enabled), do: gettext("Tickets on"), else: gettext("Tickets off")}
          </span>
        </label>

        <span
          :if={@dirty > 0}
          id="unsaved"
          class="flex items-center gap-2 whitespace-nowrap text-[0.8125rem] text-warning"
        >
          <span class="size-[7px] rounded-full bg-warning"></span>
          {ngettext("1 unsaved change", "%{count} unsaved changes", @dirty)}
        </span>
        <button
          :if={@dirty > 0}
          type="button"
          id="settings-discard"
          phx-click="discard"
          class="h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:border-base-content/30"
        >
          {gettext("Discard")}
        </button>
        <button
          type="submit"
          id="settings-save"
          form="ticket-settings-form"
          phx-disable-with={gettext("Saving...")}
          class="inbox-solid h-12 cursor-pointer rounded-full px-[1.375rem] text-sm font-semibold transition-opacity hover:opacity-90"
        >
          {gettext("Save changes")}
        </button>
      </:actions>

      <.form
        for={@form}
        id="ticket-settings-form"
        phx-change="validate"
        phx-submit="save"
        class="grid grid-cols-[minmax(0,1fr)] gap-5 md:mt-4 min-[80rem]:min-h-[calc(100dvh-8.75rem)] lg:grid-cols-2 min-[85rem]:grid-cols-[25rem_minmax(0,1fr)_25.625rem]"
      >
        <div class="flex min-w-0 flex-col gap-5">
          <TicketComponents.panel id="settings-categories" class="gap-2 p-[1.375rem]">
            <div class="mb-1.5 flex items-baseline">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
                {gettext("Categories")}
              </h2>
              <button
                type="button"
                id="add-category"
                phx-click="add_category"
                class="h-[1.875rem] cursor-pointer rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs transition-colors hover:border-base-content/40"
              >
                + {gettext("New")}
              </button>
            </div>
            <TicketSettingsForm.category_editor
              rows={@rows.categories}
              editing={@editing_category}
              counts={@category_counts}
            />
            <p
              :for={error <- @form[:category_priorities].errors}
              :if={@changeset.action}
              class="text-xs text-error"
            >
              {translate_error(error)}
            </p>
            <span class="px-1 pt-1 text-xs text-muted">
              {gettext("The player picks the category in game by answering with its number.")}
            </span>
          </TicketComponents.panel>

          <TicketComponents.panel id="settings-autoclose" class="gap-3.5 p-[1.375rem]">
            <div class="flex items-center gap-3">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
                {gettext("Close on its own")}
              </h2>
              <TicketSettingsForm.switch
                name="settings[auto_close_on]"
                id="settings_auto_close_on"
                checked={(@current.auto_close_hours || 0) > 0}
                label={gettext("Close tickets automatically")}
              />
            </div>
            <div class="flex flex-wrap items-center gap-2.5 text-sm text-subtle">
              {gettext("No activity on the ticket for")}
              <label class="flex h-9 items-center gap-1.5 rounded-xl border border-(--inbox-field-line) bg-secondary px-3 text-base-content">
                <input
                  type="number"
                  name="settings[auto_close_hours]"
                  min="1"
                  max="168"
                  value={max(@current.auto_close_hours || 0, 1)}
                  aria-label={gettext("Hours")}
                  class="w-9 border-0 bg-transparent p-0 text-right font-mono text-sm outline-none focus:ring-0"
                />
                <span class="text-[0.8125rem] text-muted">{gettext("hours")}</span>
              </label>
            </div>
            <label class="flex cursor-pointer items-center gap-2.5 text-[0.8125rem] text-subtle">
              <input type="hidden" name="settings[warn_before_close]" value="false" />
              <input
                type="checkbox"
                name="settings[warn_before_close]"
                value="true"
                checked={field_value(@form, :warn_before_close)}
                class="size-[1.125rem] accent-[var(--color-primary)]"
              />
              {gettext("Warn the player 1 h before closing")}
            </label>
          </TicketComponents.panel>

          <TicketComponents.panel id="settings-discord" class="flex-1 p-[1.375rem]">
            <div class="flex items-center gap-2.5">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
                {gettext("Discord alert")}
              </h2>
              <span class={[
                "flex items-center gap-1.5 text-xs",
                case webhook_state(@webhook) do
                  :ok -> "text-primary"
                  :error -> "text-error"
                  _other -> "text-muted"
                end
              ]}>
                <span class="size-[7px] rounded-full bg-current"></span>
                {case webhook_state(@webhook) do
                  :ok -> gettext("connected")
                  :error -> gettext("failing")
                  :untested -> gettext("not tested yet")
                  :none -> gettext("off")
                end}
              </span>
            </div>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Channel")}</span>
              <span class="flex h-11 items-center gap-2 rounded-xl border border-(--inbox-field-line) bg-secondary px-3.5">
                <span class="font-mono text-muted">#</span>
                <select
                  name="settings[discord_webhook_id]"
                  class="min-w-0 flex-1 cursor-pointer appearance-none border-0 bg-transparent p-0 text-sm outline-none focus:ring-0"
                >
                  <option value="">{gettext("Do not announce")}</option>
                  <option
                    :for={webhook <- @webhooks}
                    value={webhook.id}
                    selected={webhook.id == @current.discord_webhook_id}
                  >
                    {webhook.remote_name || webhook.name}
                  </option>
                </select>
                <.icon name="hero-chevron-down" class="size-4 text-muted" />
              </span>
            </label>
            <p :if={@webhooks == []} class="text-xs text-muted">
              {gettext("No webhook registered yet.")}
              <.link navigate={~p"/discord/new"} class="text-primary hover:underline">
                {gettext("Register one")}
              </.link>
            </p>
            <div class="flex flex-wrap items-center gap-2 text-[0.8125rem] text-subtle">
              {gettext("Mention")}
              <input
                type="text"
                name="settings[discord_mention_role_ids]"
                value={@form[:discord_mention_role_ids].value}
                placeholder={gettext("role IDs")}
                aria-label={gettext("Roles to mention")}
                class="h-[1.875rem] w-40 rounded-full border-0 bg-accent/13 px-2.5 text-xs font-semibold text-accent outline-none placeholder:font-normal placeholder:text-accent/60"
              />
              {gettext("when it is")}
              <select
                name="settings[mention_min_priority]"
                aria-label={gettext("Lowest priority that mentions")}
                class="h-[1.875rem] cursor-pointer rounded-full border border-(--inbox-field-line) bg-secondary px-2.5 text-xs outline-none"
              >
                <option
                  :for={{label, value} <- mention_options()}
                  value={value}
                  selected={value == @current.mention_min_priority}
                >
                  {label}
                </option>
              </select>
            </div>
            <p
              :for={error <- @form[:discord_mention_role_ids].errors}
              class="text-xs text-error"
            >
              {translate_error(error)}
            </p>
            <span class="flex-1"></span>
            <span :if={@last_announcement} class="text-xs text-muted" id="last-announcement">
              {gettext("Last sent at")}
              <TicketComponents.clock id="last-announcement-at" at={elem(@last_announcement, 0)} />
              · {gettext(
                "ticket #%{id}",
                id: elem(@last_announcement, 1)
              )}
            </span>
          </TicketComponents.panel>
        </div>

        <div class="flex min-w-0 flex-col gap-5">
          <TicketComponents.panel id="settings-replies" class="gap-2 p-[1.375rem]">
            <div class="mb-1.5 flex items-baseline">
              <h2 class="mr-3 whitespace-nowrap font-display text-[1.25rem] font-semibold">
                {gettext("Quick replies")}
              </h2>
              <span class="mr-2.5 min-w-0 flex-1 truncate text-xs text-muted">
                {gettext("they show above the answer")}
              </span>
              <button
                type="button"
                id="add-reply"
                phx-click="add_reply"
                class="h-[1.875rem] shrink-0 cursor-pointer whitespace-nowrap rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs transition-colors hover:border-base-content/40"
              >
                + {gettext("New")}
              </button>
            </div>
            <TicketSettingsForm.replies_editor
              rows={@rows.replies}
              editing={@editing_reply}
              uses={@reply_uses}
            />
          </TicketComponents.panel>

          <TicketComponents.panel id="settings-messages" class="flex-1 gap-2.5 p-[1.375rem]">
            <div class="mb-1 flex items-baseline">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
                {gettext("Messages in game")}
              </h2>
              <span class="text-xs text-muted">{gettext("sent to the player")}</span>
            </div>
            <TicketSettingsForm.message_editor
              field={@form[:received_message]}
              key="received"
              tag={gettext("Opened")}
              tone="warning"
              hint={gettext("when the ticket is created")}
              open={@open_message == "received"}
            />
            <TicketSettingsForm.message_editor
              field={@form[:reply_prefix]}
              key="reply"
              tag={gettext("Answered")}
              tone="engine"
              hint={gettext("prefix of the admin's answer")}
              open={@open_message == "reply"}
              max={60}
            />
            <TicketSettingsForm.message_editor
              field={@form[:closed_message]}
              key="closed"
              tag={gettext("Closed")}
              tone="neutral"
              hint={gettext("when the ticket is closed")}
              open={@open_message == "closed"}
            />
          </TicketComponents.panel>
        </div>

        <TicketComponents.panel
          id="settings-hours"
          class="gap-3.5 p-[1.375rem] lg:col-span-2 min-[85rem]:col-span-1"
        >
          <div class="flex items-center gap-3">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("Office hours")}
            </h2>
            <TicketSettingsForm.switch
              name="settings[hours_enabled]"
              id="settings_hours_enabled"
              checked={field_value(@form, :hours_enabled)}
              label={gettext("Use office hours")}
            />
          </div>
          <div class="flex items-center gap-2 text-[0.8125rem] text-subtle">
            {gettext("Zone")}
            <span class="flex h-[1.875rem] items-center rounded-full border border-(--inbox-field-line) bg-secondary px-2.5 font-mono text-xs text-base-content">
              {(@first && @first.timezone) || "Etc/UTC"}
            </span>
            <span
              :if={field_value(@form, :hours_enabled)}
              class={[
                "ml-auto flex items-center gap-1.5 text-xs",
                if(@open_now?, do: "text-primary", else: "text-muted")
              ]}
            >
              <span class="size-[7px] rounded-full bg-current"></span>
              {if @open_now?, do: gettext("open now"), else: gettext("closed now")}
            </span>
          </div>
          <TicketSettingsForm.hours_editor
            hours={@rows.hours}
            editing={@editing_day}
            now={now_marker(@first)}
          />
          <button
            type="button"
            id="add-range"
            phx-click="add_range"
            class="h-8 cursor-pointer self-start rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs transition-colors hover:border-base-content/40"
          >
            + {gettext("Time range")}
          </button>

          <div class="flex flex-col gap-2.5 border-t border-(--inbox-line) pt-3.5">
            <span class="flex items-center gap-2">
              <span class={TicketSettingsForm.tag_class("neutral")}>
                {gettext("Outside office hours")}
              </span>
              <span class="text-[0.8125rem] text-subtle">{gettext("automatic answer")}</span>
            </span>
            <textarea
              id="settings_offline_message"
              name="settings[offline_message]"
              rows="3"
              maxlength="300"
              phx-debounce="300"
              aria-label={gettext("Answer outside office hours")}
              class="resize-none rounded-xl border border-(--inbox-field-line) bg-secondary px-3 py-2.5 font-mono text-[0.8125rem] leading-normal outline-none focus:border-primary/60"
            >{@form[:offline_message].value}</textarea>
            <div class="flex items-center gap-3 rounded-[0.875rem] bg-secondary px-3 py-2.5">
              <span class="flex-1 text-[0.8125rem]">{gettext("Take tickets outside office hours")}</span>
              <TicketSettingsForm.switch
                name="settings[accept_offline]"
                id="settings_accept_offline"
                checked={field_value(@form, :accept_offline)}
                label={gettext("Take tickets outside office hours")}
              />
            </div>
            <div class="flex items-center gap-3 rounded-[0.875rem] bg-secondary px-3 py-2.5">
              <span class="flex-1 text-[0.8125rem]">
                {gettext("Urgent ones alert on Discord anyway")}
              </span>
              <TicketSettingsForm.switch
                name="settings[offline_alert_urgent]"
                id="settings_offline_alert_urgent"
                checked={field_value(@form, :offline_alert_urgent)}
                label={gettext("Urgent ones alert on Discord outside office hours")}
              />
            </div>
          </div>

          <details
            id="settings-more"
            open={@changeset.action == :validate and not @changeset.valid?}
            class="group border-t border-(--inbox-line) pt-3"
          >
            <summary class="flex cursor-pointer list-none items-center justify-between text-[0.8125rem] text-subtle [&::-webkit-details-marker]:hidden">
              {gettext("More settings")}
              <.icon
                name="hero-chevron-down"
                class="size-4 transition-transform group-open:rotate-180"
              />
            </summary>
            <div class="mt-3 grid grid-cols-2 gap-3">
              <div class="col-span-2">
                <.input
                  name="settings[commands_text]"
                  id="settings_commands_text"
                  value={Enum.join(@current.commands || [], " ")}
                  type="text"
                  label={gettext("Commands")}
                  placeholder="!admin !ajuda"
                  no_margin
                />
                <p
                  :for={error <- @form[:commands].errors}
                  :if={@changeset.action}
                  class="mt-1 text-xs text-error"
                >
                  {translate_error(error)}
                </p>
              </div>
              <.input
                field={@form[:attention_minutes]}
                type="number"
                min="0"
                max="1440"
                label={gettext("Alert after minutes without an answer")}
                no_margin
              />
              <.input
                field={@form[:max_per_hour]}
                type="number"
                min="0"
                max="60"
                label={gettext("Tickets per player per hour")}
                no_margin
              />
              <.input
                field={@form[:default_priority]}
                type="select"
                options={Labels.ticket_priority_options()}
                label={gettext("Priority without a category")}
                no_margin
              />
              <div></div>
              <.input
                field={@form[:status_word]}
                type="text"
                label={gettext("Word to check the ticket")}
                placeholder="status"
                no_margin
              />
              <.input
                field={@form[:close_word]}
                type="text"
                label={gettext("Word to close the ticket")}
                placeholder="close"
                no_margin
              />
            </div>
          </details>
        </TicketComponents.panel>
      </.form>
    </Layouts.app>
    """
  end

  defp mention_options do
    [
      {gettext("any priority"), "low"},
      {gettext("Normal or above"), "normal"},
      {gettext("High or Urgent"), "high"},
      {gettext("Urgent only"), "urgent"}
    ]
  end
end
