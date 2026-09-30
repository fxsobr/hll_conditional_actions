defmodule HllConditionalActionsWeb.TicketLive.Setup do
  @moduledoc """
  The ticket setup wizard: the choices that matter to get tickets working,
  one step at a time, beside a live picture of what the player sees in game.

    1. servers - only from `/tickets/setup`, where nothing picks one
    2. commands - what players type, whether case matters, whether a bare
       command asks for the reason, the wait between calls, how many
       tickets at once, who may call and who never may
    3. categories - suggested ones to keep, recolour or drop
    4. messages - what the player reads
    5. office hours - optional
    6. review - a summary, and switching tickets on

  The steps share one set of values, so going back and forth keeps what was
  typed; each "Continue" checks only the fields of the step it leaves.
  While tickets are still off for the servers, every step saves a draft
  (tickets stay off); nothing reaches the game until the review switches
  them on. The quick replies and the Discord alert live in the settings
  page.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_tickets}}

  import Ecto.Query, only: [from: 2]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActionsWeb.TicketComponents
  alias HllConditionalActionsWeb.TicketSettingsForm

  @form_steps [:commands, :categories, :messages, :schedule]

  # Which stored fields each step edits, to hold a step's errors against it.
  @step_fields %{
    commands: [
      :commands,
      :ignore_case,
      :ask_reason,
      :cooldown_seconds,
      :max_open_per_player,
      :audience,
      :min_playtime_hours,
      :blocked_flags,
      :block_recent_bans
    ],
    categories: [:category_priorities, :category_colors, :category_order],
    messages: [:received_message, :reply_prefix, :closed_message],
    schedule: [:hours_enabled, :hours_ranges, :hours_start, :offline_message]
  }

  @cooldowns [60, 180, 300, 600]

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
       |> assign(:selected, [server.id])
       |> assign(:steps, @form_steps ++ [:review])
       |> assign(:step, :commands)
       |> load_base(server.id)}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not have access to that page."))
         |> push_navigate(to: ~p"/tickets")}
    end
  end

  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns.current_user)
    first = Enum.take(Enum.map(servers, & &1.id), 1)

    {:ok,
     socket
     |> base_assigns()
     |> assign(:server, nil)
     |> assign(:servers, servers)
     |> assign(:selected, first)
     |> assign(:steps, [:servers | @form_steps] ++ [:review])
     |> assign(:step, :servers)
     |> load_base(List.first(first))}
  end

  defp base_assigns(socket) do
    socket
    |> assign(:page_title, gettext("Inbox"))
    |> assign(:scenario, "first")
    |> assign(:draft_saved_at, nil)
    |> assign(:editing_category, nil)
    |> assign(:editing_day, nil)
    |> assign(:open_message, "received")
    |> assign(:adding_block?, false)
  end

  # The wizard starts from what the (first) server has, or the suggestions.
  defp load_base(socket, server_id) do
    settings =
      case server_id && Tickets.get_settings(server_id) do
        nil -> TicketSettingsForm.defaults(%Settings{})
        %Settings{id: nil} = fresh -> TicketSettingsForm.defaults(fresh)
        saved -> saved
      end

    rows = TicketSettingsForm.rows(settings)

    socket
    |> assign(:settings, settings)
    |> assign(:params, %{})
    |> assign(:rows, rows)
    |> assign(:commands, settings.commands || [])
    |> assign(:blocked_flags, settings.blocked_flags || [])
    |> assign(:sample, sample_call(server_id, socket.assigns.current_user))
    |> build()
  end

  # The newest real call on the server, to show the preview with; the
  # admin's own name when there is none yet.
  defp sample_call(nil, user), do: %{player: user.name || user.username, text: nil, id: nil}

  defp sample_call(server_id, user) do
    ticket =
      Repo.one(
        from t in Ticket,
          where: t.server_id == ^server_id and t.source == :chat,
          order_by: [desc: t.inserted_at],
          limit: 1,
          preload: [:messages]
      )

    case ticket do
      nil ->
        sample_call(nil, user)

      ticket ->
        first = Enum.find(ticket.messages, &(&1.author == :player))

        %{
          player: ticket.player_name || ticket.player_id,
          text: first && first.body,
          id: ticket.id
        }
    end
  end

  # The wizard is there to switch tickets on, so its values are checked as
  # if they were (a command is required); saving says what `enabled` is.
  defp build(socket, action \\ nil) do
    changeset =
      socket.assigns.settings
      |> Tickets.change_settings(Map.put(attrs(socket.assigns), "enabled", true))
      |> Map.put(:action, action)

    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :settings))
    |> assign(:current, Ecto.Changeset.apply_changes(changeset))
  end

  defp attrs(assigns) do
    %{params: params, rows: rows} = assigns

    params
    |> TicketSettingsForm.parse()
    |> Map.merge(%{
      "commands" => assigns.commands,
      "blocked_flags" => assigns.blocked_flags,
      "category_priorities" => Map.new(rows.categories, &{&1["name"], &1["priority"]}),
      "category_colors" => Map.new(rows.categories, &{&1["name"], &1["color"]}),
      "category_order" => Enum.map(rows.categories, & &1["name"]),
      "hours_ranges" => rows.hours
    })
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
        hours:
          if(Map.has_key?(params, "hours"),
            do: TicketSettingsForm.hour_rows(params),
            else: rows.hours
          )
    }

    fields = Map.drop(params, ["categories", "hours"])

    {:noreply,
     socket
     |> assign(:params, Map.merge(socket.assigns.params, fields))
     |> assign(:rows, rows)
     |> build(socket.assigns.changeset.action)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("select_servers", params, socket) do
    allowed = MapSet.new(socket.assigns.servers, & &1.id)

    ids =
      params
      |> Map.get("server_ids", [])
      |> Enum.flat_map(&TicketSettingsForm.parse_id/1)
      |> Enum.filter(&MapSet.member?(allowed, &1))

    socket = assign(socket, :selected, ids)

    # One server ticked: start from what it has.
    socket = if length(ids) == 1, do: load_base(socket, hd(ids)), else: socket
    {:noreply, socket}
  end

  def handle_event("add_command", %{"command" => command}, socket) do
    commands =
      (socket.assigns.commands ++ [command])
      |> Settings.normalize_commands()

    {:noreply, socket |> assign(:commands, commands) |> build(socket.assigns.changeset.action)}
  end

  def handle_event("remove_command", %{"command" => command}, socket) do
    commands = List.delete(socket.assigns.commands, command)
    {:noreply, socket |> assign(:commands, commands) |> build(socket.assigns.changeset.action)}
  end

  def handle_event("max_open", %{"delta" => delta}, socket) do
    value = (socket.assigns.current.max_open_per_player || 1) + String.to_integer(delta)
    value = value |> max(1) |> min(5)
    params = Map.put(socket.assigns.params, "max_open_per_player", to_string(value))
    {:noreply, socket |> assign(:params, params) |> build(socket.assigns.changeset.action)}
  end

  def handle_event("toggle_adding_block", _params, socket),
    do: {:noreply, assign(socket, :adding_block?, !socket.assigns.adding_block?)}

  def handle_event("add_flag", %{"flag" => flag}, socket) do
    flags = Settings.normalize_flags(socket.assigns.blocked_flags ++ [flag])

    {:noreply,
     socket
     |> assign(:blocked_flags, flags)
     |> assign(:adding_block?, false)
     |> build(socket.assigns.changeset.action)}
  end

  def handle_event("remove_flag", %{"flag" => flag}, socket) do
    flags = List.delete(socket.assigns.blocked_flags, flag)
    {:noreply, socket |> assign(:blocked_flags, flags) |> build(socket.assigns.changeset.action)}
  end

  def handle_event("toggle_recent_bans", _params, socket) do
    value = !socket.assigns.current.block_recent_bans
    params = Map.put(socket.assigns.params, "block_recent_bans", to_string(value))

    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(:adding_block?, false)
     |> build(socket.assigns.changeset.action)}
  end

  def handle_event("scenario", %{"scenario" => scenario}, socket)
      when scenario in ~w(first again bare),
      do: {:noreply, assign(socket, :scenario, scenario)}

  def handle_event("add_category", _params, socket) do
    categories = socket.assigns.rows.categories

    row = %{
      "name" => "",
      "priority" => "normal",
      "color" => Settings.color_for(nil, length(categories))
    }

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

  def handle_event("reorder_categories", %{"order" => order}, socket) do
    rows = socket.assigns.rows.categories
    indexes = Enum.map(order, &parse_index/1)

    if Enum.sort(indexes) == Enum.to_list(0..(length(rows) - 1)//1),
      do: {:noreply, update_rows(socket, :categories, Enum.map(indexes, &Enum.at(rows, &1)))},
      else: {:noreply, socket}
  end

  def handle_event("open_message", %{"key" => key}, socket),
    do: {:noreply, assign(socket, :open_message, key)}

  def handle_event("edit_day", %{"day" => day}, socket) do
    day = if day == socket.assigns.editing_day, do: nil, else: day
    {:noreply, assign(socket, :editing_day, day)}
  end

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

  def handle_event("back", _params, socket), do: {:noreply, move(socket, -1)}

  def handle_event("next", _params, %{assigns: %{step: :servers, selected: []}} = socket),
    do: {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

  def handle_event("next", _params, socket) do
    step = socket.assigns.step
    changeset = Map.put(socket.assigns.changeset, :action, :validate)

    # Only the fields of the step being left are held against it.
    step_errors? =
      step in @form_steps and
        Enum.any?(changeset.errors, fn {field, _} -> field in @step_fields[step] end)

    if step_errors? do
      {:noreply, build(socket, :validate)}
    else
      {:noreply, socket |> save_draft() |> move(1)}
    end
  end

  def handle_event("goto", %{"step" => step}, socket) do
    steps = socket.assigns.steps
    target = Enum.find(steps, &(to_string(&1) == step))

    # Only steps already passed can be jumped back to.
    if target && index(steps, target) < index(steps, socket.assigns.step),
      do: {:noreply, assign(socket, :step, target)},
      else: {:noreply, socket}
  end

  def handle_event("save_exit", _params, socket) do
    case save(socket, %{"enabled" => socket.assigns.settings.enabled}) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Saved. Tickets stay as they were until you switch them on.")
         )
         |> push_navigate(to: ~p"/inbox")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("finish", _params, socket) do
    case save(socket, %{"enabled" => true}) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Tickets are set up. Players can call an admin now."))
         |> push_navigate(to: done_path(socket))}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp save(%{assigns: %{selected: []}} = socket, _extra),
    do: {:error, put_flash(socket, :error, gettext("Pick at least one server."))}

  defp save(socket, extra) do
    attrs = Map.merge(attrs(socket.assigns), extra)
    changeset = Tickets.change_settings(socket.assigns.settings, Map.put(attrs, "enabled", true))

    if changeset.valid? do
      Enum.each(socket.assigns.selected, fn id ->
        {:ok, _saved} = Tickets.save_settings(Tickets.get_settings(id), attrs)
      end)

      {:ok, socket}
    else
      {:error,
       socket
       |> build(:validate)
       |> put_flash(:error, gettext("Something needs fixing: see the highlighted step."))
       |> assign(:step, first_step_with_errors(changeset))}
    end
  end

  # A draft is kept while tickets are off on every server of the wizard;
  # once they are on, changes wait for the review, so nothing half-done
  # reaches the players.
  defp save_draft(%{assigns: %{selected: []}} = socket), do: socket

  defp save_draft(socket) do
    ids = socket.assigns.selected
    all_off? = Enum.all?(ids, &(not Tickets.get_settings(&1).enabled))
    attrs = attrs(socket.assigns) |> Map.put("enabled", false)

    if all_off? and Tickets.change_settings(socket.assigns.settings, attrs).valid? do
      Enum.each(ids, fn id ->
        {:ok, _saved} = Tickets.save_settings(Tickets.get_settings(id), attrs)
      end)

      assign(socket, :draft_saved_at, DateTime.utc_now())
    else
      socket
    end
  end

  defp first_step_with_errors(changeset) do
    Enum.find(@form_steps, :commands, fn step ->
      Enum.any?(changeset.errors, fn {field, _} -> field in @step_fields[step] end)
    end)
  end

  defp done_path(%{assigns: %{server: nil}}), do: ~p"/inbox"
  defp done_path(%{assigns: %{server: server}}), do: ~p"/servers/#{server.id}/tickets"

  defp move(socket, delta) do
    steps = socket.assigns.steps
    next = Enum.at(steps, max(0, index(steps, socket.assigns.step) + delta))
    assign(socket, :step, next || socket.assigns.step)
  end

  defp index(steps, step), do: Enum.find_index(steps, &(&1 == step))

  defp update_rows(socket, group, value) do
    socket
    |> assign(:rows, Map.put(socket.assigns.rows, group, value))
    |> build(socket.assigns.changeset.action)
  end

  defp parse_index(index) do
    case Integer.parse(to_string(index)) do
      {index, ""} -> index
      _other -> nil
    end
  end

  # ── Labels ─────────────────────────────────────────────────────────────────

  defp step_title(:servers), do: gettext("Servers")
  defp step_title(:commands), do: gettext("Commands")
  defp step_title(:categories), do: gettext("Categories")
  defp step_title(:messages), do: gettext("Messages")
  defp step_title(:schedule), do: gettext("Office hours")
  defp step_title(:review), do: gettext("Review")

  # One line under each step's name: what was chosen there so far.
  defp step_summary(:servers, assigns) do
    case Enum.filter(assigns.servers, &(&1.id in assigns.selected)) do
      [] -> gettext("none picked yet")
      [server] -> server.name
      [one, two] -> gettext("%{one} and %{two}", one: one.name, two: two.name)
      servers -> ngettext("1 server", "%{count} servers", length(servers))
    end
  end

  defp step_summary(:commands, assigns) do
    case assigns.commands do
      [] ->
        gettext("no command yet")

      commands ->
        ngettext("1 command", "%{count} commands", length(commands)) <>
          " · " <> gettext("wait %{time}", time: wait_label(assigns.current.cooldown_seconds))
    end
  end

  defp step_summary(:categories, assigns) do
    case Enum.count(assigns.rows.categories, &(&1["name"] != "")) do
      0 -> gettext("optional")
      count -> ngettext("1 category", "%{count} categories", count)
    end
  end

  defp step_summary(:messages, _assigns), do: gettext("opened, answered, closed")

  defp step_summary(:schedule, assigns) do
    if assigns.current.hours_enabled, do: gettext("on"), else: gettext("optional")
  end

  defp step_summary(:review, _assigns), do: gettext("test and switch on")

  defp wait_label(seconds) when is_integer(seconds) and seconds > 0 and rem(seconds, 60) == 0,
    do: gettext("%{count} min", count: div(seconds, 60))

  defp wait_label(seconds) when is_integer(seconds) and seconds > 0,
    do: gettext("%{count} s", count: seconds)

  defp wait_label(_none), do: gettext("none")

  defp cooldown_choice(seconds) when seconds in @cooldowns, do: to_string(div(seconds, 60))
  defp cooldown_choice(_seconds), do: "other"

  # What the player reads in game for the scenario on the preview.
  defp preview_message(assigns) do
    %{current: settings, sample: sample} = assigns
    ticket = %{id: sample.id || 214, player_name: sample.player, category: nil}
    server = List.first(Enum.filter(assigns.servers, &(&1.id in assigns.selected)))

    template =
      case assigns.scenario do
        "first" ->
          settings.received_message

        "again" ->
          Tickets.already_open_text()

        "bare" ->
          if settings.ask_reason, do: ask_reason_preview(), else: settings.received_message
      end

    Tickets.render_notice(template || "", ticket, settings, server)
  end

  defp ask_reason_preview,
    do: gettext("Tell us what happened: type it here in the chat and it joins your ticket.")

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:position, index(assigns.steps, assigns.step))
      |> assign(
        :preview_server,
        List.first(Enum.filter(assigns.servers, &(&1.id in assigns.selected)))
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
        <span
          :if={@draft_saved_at}
          id="draft-saved"
          class="flex items-center gap-2 whitespace-nowrap text-[0.8125rem] text-muted"
        >
          <.icon name="hero-check-circle" class="size-4" />
          {gettext("Draft saved at")}
          <TicketComponents.clock id="draft-saved-at" at={@draft_saved_at} />
        </span>
        <button
          type="button"
          id="wizard-save-exit"
          phx-click="save_exit"
          class="h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:border-base-content/30"
        >
          {gettext("Save and exit")}
        </button>
      </:actions>

      <form id="command-add" phx-submit="add_command" phx-change="validate" class="hidden"></form>
      <form id="server-picker" phx-change="select_servers" class="hidden"></form>
      <form id="flag-add" phx-submit="add_flag" phx-change="validate" class="hidden"></form>

      <div class="grid grid-cols-[minmax(0,1fr)] gap-5 md:mt-4 lg:grid-cols-[16.875rem_minmax(0,1fr)] min-[80rem]:min-h-[calc(100dvh-8.75rem)] min-[85rem]:grid-cols-[16.875rem_minmax(0,1fr)_26.875rem]">
        <section
          aria-label={gettext("Steps")}
          class="inbox-panel flex flex-col gap-1.5 rounded-[1.75rem] bg-base-100 px-[1.125rem] py-[1.375rem]"
        >
          <div class="flex flex-col gap-2 px-1.5 pb-3.5">
            <span class="text-xs uppercase tracking-[0.06em] text-muted">
              {gettext("Step %{current} of %{total}", current: @position + 1, total: length(@steps))}
            </span>
            <span class="flex h-1.5 rounded-[3px] bg-base-300" aria-hidden="true">
              <span
                class="rounded-[3px] bg-primary transition-all"
                style={"width: #{round(@position / max(length(@steps) - 1, 1) * 100)}%"}
              ></span>
            </span>
          </div>

          <ol id="wizard-steps" class="flex flex-col gap-1" aria-label={gettext("Steps")}>
            <li :for={{step, index} <- Enum.with_index(@steps)}>
              <button
                type="button"
                phx-click="goto"
                phx-value-step={step}
                disabled={index >= @position}
                aria-current={step == @step && "step"}
                class={[
                  "flex w-full items-center gap-3 rounded-2xl border p-3 text-left transition-colors",
                  if(step == @step,
                    do: "border-(--inbox-strong) bg-secondary",
                    else: "border-transparent"
                  ),
                  index < @position && "cursor-pointer hover:bg-secondary/60"
                ]}
              >
                <span class={[
                  "flex size-[1.875rem] shrink-0 items-center justify-center rounded-full font-mono text-xs",
                  index < @position && "bg-primary text-primary-content",
                  step == @step && "border-2 border-primary font-medium text-primary",
                  index > @position && "border border-(--inbox-strong) text-subtle"
                ]}>
                  <.icon :if={index < @position} name="hero-check" class="size-4" />
                  <span :if={index >= @position}>{index + 1}</span>
                </span>
                <span class="flex min-w-0 flex-col gap-0.5">
                  <span class={[
                    "truncate text-sm",
                    if(index > @position, do: "font-medium text-subtle", else: "font-semibold")
                  ]}>
                    {step_title(step)}
                  </span>
                  <span class={[
                    "truncate text-xs",
                    if(step == @step, do: "text-subtle", else: "text-muted")
                  ]}>
                    {step_summary(step, assigns)}
                  </span>
                </span>
              </button>
            </li>
          </ol>

          <span class="flex-1"></span>
          <p class="mt-3 flex gap-2.5 rounded-[1.125rem] border border-accent/25 bg-accent/8 p-3.5 text-[0.8125rem] leading-normal">
            <.icon name="hero-information-circle" class="size-4 shrink-0 text-accent" />
            <span class="inbox-note-text">
              {gettext("Nothing changes in the game until you switch tickets on in the review.")}
            </span>
          </p>
        </section>

        <section class="inbox-panel flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100">
          <.form
            for={@form}
            id="wizard-form"
            phx-change="validate"
            phx-submit="next"
            class="flex flex-1 flex-col gap-[1.625rem] px-7 py-[1.625rem]"
          >
            <%= case @step do %>
              <% :servers -> %>
                <.step_heading
                  title={gettext("Which servers take tickets")}
                  text={gettext("Tick every server where players can call an admin from the chat.")}
                />
                <div id="server-choices" class="grid gap-2 sm:grid-cols-2">
                  <input type="hidden" name="server_ids[]" value="" form="server-picker" />
                  <label
                    :for={server <- @servers}
                    class="flex cursor-pointer items-center gap-2.5 rounded-2xl border border-(--inbox-field-line) bg-secondary px-3.5 py-3 transition-colors has-[:checked]:border-primary/50 has-[:checked]:bg-primary/8"
                  >
                    <input
                      type="checkbox"
                      name="server_ids[]"
                      value={server.id}
                      form="server-picker"
                      checked={server.id in @selected}
                      class="size-4 accent-[var(--color-primary)]"
                    />
                    <span class="truncate font-medium">{server.name}</span>
                  </label>
                  <p :if={@servers == []} class="text-sm text-muted">
                    {gettext("You have no server yet.")}
                  </p>
                </div>
              <% :commands -> %>
                <.commands_step
                  commands={@commands}
                  form={@form}
                  current={@current}
                  blocked_flags={@blocked_flags}
                  adding_block?={@adding_block?}
                  errors={if @changeset.action, do: @form[:commands].errors, else: []}
                />
              <% :categories -> %>
                <.step_heading
                  title={gettext("What the calls are about")}
                  text={
                    gettext(
                      "Each category opens tickets at its own priority. The player picks one by answering with its number, or by typing its name after the command."
                    )
                  }
                />
                <div class="flex items-baseline">
                  <span class="flex-1 font-mono text-[0.6875rem] uppercase tracking-[0.1em] text-muted">
                    {gettext("Suggested categories")}
                  </span>
                  <button
                    type="button"
                    phx-click="add_category"
                    class="h-[1.875rem] cursor-pointer rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs"
                  >
                    + {gettext("New")}
                  </button>
                </div>
                <TicketSettingsForm.category_editor
                  rows={@rows.categories}
                  editing={@editing_category}
                />
              <% :messages -> %>
                <.step_heading
                  title={gettext("What the player reads")}
                  text={
                    gettext(
                      "Leave a message blank to send nothing. The chips add the ticket's details."
                    )
                  }
                />
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
              <% :schedule -> %>
                <div class="flex items-start gap-4">
                  <.step_heading
                    title={gettext("When a player can expect an answer")}
                    text={
                      gettext(
                        "Outside these hours the player reads the answer below and the ticket waits for an admin."
                      )
                    }
                  />
                  <TicketSettingsForm.switch
                    name="settings[hours_enabled]"
                    id="settings_hours_enabled"
                    checked={@current.hours_enabled}
                    label={gettext("Use office hours")}
                  />
                </div>
                <TicketSettingsForm.hours_editor hours={@rows.hours} editing={@editing_day} />
                <button
                  type="button"
                  phx-click="add_range"
                  class="h-8 cursor-pointer self-start rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs"
                >
                  + {gettext("Time range")}
                </button>
                <textarea
                  id="settings_offline_message"
                  name="settings[offline_message]"
                  rows="3"
                  maxlength="300"
                  phx-debounce="300"
                  aria-label={gettext("Answer outside office hours")}
                  class="resize-none rounded-xl border border-(--inbox-field-line) bg-secondary px-3 py-2.5 font-mono text-[0.8125rem] leading-normal outline-none focus:border-primary/60"
                >{@current.offline_message}</textarea>
              <% :review -> %>
                <.review_step
                  current={@current}
                  commands={@commands}
                  rows={@rows}
                  servers={Enum.filter(@servers, &(&1.id in @selected))}
                />
            <% end %>
          </.form>

          <footer class="flex items-center gap-3 border-t border-(--inbox-line) px-6 py-4">
            <button
              :if={@position > 0}
              type="button"
              id="wizard-back"
              phx-click="back"
              class="flex h-12 cursor-pointer items-center gap-2 rounded-full border border-base-300 bg-secondary pl-4 pr-5 text-sm transition-colors hover:border-base-content/30"
            >
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </button>
            <span class="flex-1 text-center text-[0.8125rem] text-muted">
              <span :if={@step != :review}>
                {gettext("Next: %{step}", step: step_title(Enum.at(@steps, @position + 1)))}
              </span>
            </span>
            <button
              :if={@step != :review}
              type="button"
              id="wizard-next"
              phx-click="next"
              class="inbox-solid flex h-12 cursor-pointer items-center gap-2 rounded-full pl-[1.375rem] pr-[1.125rem] text-sm font-semibold transition-opacity hover:opacity-90"
            >
              {gettext("Continue")} <.icon name="hero-arrow-right" class="size-4" />
            </button>
            <button
              :if={@step == :review}
              type="button"
              id="wizard-finish"
              phx-click="finish"
              phx-disable-with={gettext("Saving...")}
              class="inbox-solid flex h-12 cursor-pointer items-center gap-2 rounded-full px-[1.375rem] text-sm font-semibold transition-opacity hover:opacity-90"
            >
              <.icon name="hero-check" class="size-4" /> {gettext("Save and turn on")}
            </button>
          </footer>
        </section>

        <section
          id="wizard-preview-panel"
          aria-label={gettext("How the player sees it")}
          class="inbox-panel flex flex-col gap-3.5 rounded-[1.75rem] bg-base-100 p-[1.375rem] lg:col-span-2 min-[85rem]:col-span-1"
        >
          <div class="flex items-baseline">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("How the player sees it")}
            </h2>
            <span class="flex items-center gap-1.5 text-xs text-primary">
              <span class="size-[7px] rounded-full bg-current"></span>{gettext("live")}
            </span>
          </div>
          <div
            role="tablist"
            aria-label={gettext("Scenario")}
            class="flex gap-1 rounded-full bg-secondary p-1"
          >
            <button
              :for={
                {key, label} <- [
                  {"first", gettext("1st call")},
                  {"again", gettext("Called again")},
                  {"bare", gettext("No reason")}
                ]
              }
              type="button"
              role="tab"
              phx-click="scenario"
              phx-value-scenario={key}
              aria-selected={to_string(@scenario == key)}
              class={[
                "h-8 flex-1 cursor-pointer rounded-full text-xs transition-colors",
                if(@scenario == key,
                  do: "bg-base-content font-semibold text-base-100",
                  else: "text-subtle hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <div
            id="wizard-preview"
            class="relative h-[20.625rem] shrink-0 overflow-hidden rounded-[1.25rem] bg-gray-950"
          >
            <img
              src={server_art(@preview_server)}
              alt=""
              class="absolute inset-0 size-full object-cover opacity-55"
            />
            <div class="absolute inset-0 bg-[linear-gradient(180deg,rgba(15,16,14,0.2)_0%,rgba(15,16,14,0.55)_45%,rgba(15,16,14,0.92)_100%)]">
            </div>
            <div
              :if={preview_message(assigns) != ""}
              class="absolute left-1/2 top-[1.125rem] flex w-[18.75rem] max-w-[calc(100%-2rem)] -translate-x-1/2 flex-col gap-1.5 rounded-md border border-gray-50/25 bg-gray-950/90 px-3.5 py-2.5"
            >
              <span class="font-mono text-[0.625rem] tracking-[0.14em] text-gray-400">
                {gettext("ADMIN MESSAGE")}
              </span>
              <span id="wizard-preview-message" class="font-mono text-xs leading-normal text-gray-50">
                {preview_message(assigns)}
              </span>
            </div>
            <div class="absolute inset-x-4 bottom-3.5 flex flex-col gap-[0.3125rem] font-mono text-xs leading-[1.45]">
              <span class="text-gray-50">
                [{gettext("Team")}] <span class="text-[#8CC4FF]">{@sample.player}</span>:
                <span class="text-primary-300">{List.first(@commands, "!admin")}</span>
                <span :if={@scenario != "bare"}>{@sample.text || gettext("the reason")}</span>
              </span>
              <span class="mt-1 flex items-center gap-2 rounded bg-gray-50/8 px-2.5 py-1.5 text-gray-500">
                &gt; <span class="h-[0.8125rem] w-[7px] bg-gray-400"></span>
              </span>
            </div>
          </div>

          <div class="flex flex-col gap-1">
            <span class="mb-1.5 text-xs uppercase tracking-[0.06em] text-muted">{gettext("The flow")}</span>
            <div class="grid grid-cols-[1.375rem_minmax(0,1fr)] gap-2.5 py-2">
              <span class="flex size-[1.375rem] items-center justify-center rounded-full bg-base-300 font-mono text-[0.6875rem]">1</span>
              <span class="text-[0.8125rem] leading-normal text-subtle">
                {gettext("Types")}
                <%= for {command, index} <- Enum.with_index(@commands) do %>
                  <span :if={index > 0}>{if index == length(@commands) - 1,
                    do: gettext("or"),
                    else: ","}</span>
                  <span class="font-mono text-base-content">{command}</span>
                <% end %>
                {gettext("with the reason")}
              </span>
            </div>
            <div class="grid grid-cols-[1.375rem_minmax(0,1fr)] gap-2.5 py-2">
              <span class="flex size-[1.375rem] items-center justify-center rounded-full bg-base-300 font-mono text-[0.6875rem]">2</span>
              <span class="text-[0.8125rem] leading-normal text-subtle">
                {gettext("Gets the confirmation above, and the ticket enters the Inbox")}
              </span>
            </div>
            <div
              :if={(@current.cooldown_seconds || 0) > 0}
              class="grid grid-cols-[1.375rem_minmax(0,1fr)] gap-2.5 py-2"
            >
              <span class="flex size-[1.375rem] items-center justify-center rounded-full bg-base-300 font-mono text-[0.6875rem]">3</span>
              <span class="text-[0.8125rem] leading-normal text-subtle">
                {gettext("If they call again within %{time}:",
                  time: wait_label(@current.cooldown_seconds)
                )}
              </span>
            </div>
            <div
              :if={(@current.cooldown_seconds || 0) > 0}
              class="ml-8 rounded-[0.625rem] border border-base-300 bg-base-200 px-3 py-2.5 font-mono text-xs leading-normal"
            >
              {Tickets.render_notice(
                Tickets.already_open_text(),
                %{id: @sample.id || 214, player_name: @sample.player},
                @current
              )}
            </div>
          </div>
          <span class="flex-1"></span>
          <span :if={@preview_server} class="text-xs text-muted">
            {gettext("Simulated with %{player} on %{server}",
              player: @sample.player,
              server: @preview_server.name
            )}
          </span>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :text, :string, required: true

  defp step_heading(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col gap-1.5">
      <h2 id="wizard-title" class="font-display text-[1.375rem] font-semibold">{@title}</h2>
      <span class="text-sm leading-normal text-subtle">{@text}</span>
    </div>
    """
  end

  attr :commands, :list, required: true
  attr :form, :any, required: true
  attr :current, :any, required: true
  attr :blocked_flags, :list, required: true
  attr :adding_block?, :boolean, required: true
  attr :errors, :list, default: []

  defp commands_step(assigns) do
    ~H"""
    <.step_heading
      title={gettext("How the player calls an admin")}
      text={
        gettext(
          "The player types one of these commands in the game chat. The text after the command becomes the ticket's first message."
        )
      }
    />

    <div class="flex flex-col gap-3">
      <span class="font-mono text-[0.6875rem] uppercase tracking-[0.1em] text-muted">
        {gettext("Commands in the chat")}
      </span>
      <div
        id="command-chips"
        class="flex flex-wrap items-center gap-2 rounded-2xl border border-(--inbox-field-line) bg-secondary p-2"
      >
        <span
          :for={command <- @commands}
          class="flex h-9 items-center gap-1 rounded-full border border-primary/40 bg-primary/12 pl-3.5 pr-1.5 font-mono text-sm text-primary"
        >
          {command}
          <button
            type="button"
            phx-click="remove_command"
            phx-value-command={command}
            aria-label={gettext("Remove %{command}", command: command)}
            class="size-[1.625rem] cursor-pointer rounded-full text-[0.9375rem] hover:bg-primary/15"
          >
            ×
          </button>
        </span>
        <input
          type="text"
          name="command"
          form="command-add"
          id={"command-input-#{length(@commands)}"}
          aria-label={gettext("Add a command")}
          placeholder={gettext("+ new command, e.g. !call")}
          class="h-9 min-w-40 flex-1 border-0 bg-transparent px-2 font-mono text-[0.8125rem] outline-none placeholder:text-muted focus:ring-0"
        />
      </div>
      <p :for={error <- @errors} class="text-xs text-error">{translate_error(error)}</p>
      <div class="grid gap-2.5 sm:grid-cols-2">
        <div class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3">
          <span class="flex flex-1 flex-col gap-0.5">
            <span class="text-sm">{gettext("Ignore case")}</span>
            <span class="text-xs text-muted">
              <span class="font-mono">{String.upcase(List.first(@commands, "!admin"))}</span>
              {gettext("works too")}
            </span>
          </span>
          <TicketSettingsForm.switch
            name="settings[ignore_case]"
            id="settings_ignore_case"
            checked={@current.ignore_case}
            label={gettext("Ignore case")}
          />
        </div>
        <div class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3">
          <span class="flex flex-1 flex-col gap-0.5">
            <span class="text-sm">{gettext("Ask for the reason")}</span>
            <span class="text-xs text-muted">
              {gettext("when only %{command} comes, without text",
                command: List.first(@commands, "!admin")
              )}
            </span>
          </span>
          <TicketSettingsForm.switch
            name="settings[ask_reason]"
            id="settings_ask_reason"
            checked={@current.ask_reason}
            label={gettext("Ask for the reason")}
          />
        </div>
      </div>
    </div>

    <div class="flex flex-col gap-3">
      <span class="font-mono text-[0.6875rem] uppercase tracking-[0.1em] text-muted">
        {gettext("Wait per player")}
      </span>
      <div class="flex flex-wrap items-center gap-3.5">
        <div
          role="radiogroup"
          aria-label={gettext("Wait between calls")}
          class="flex shrink-0 gap-1 rounded-full border border-(--inbox-field-line) bg-secondary p-1"
        >
          <label
            :for={
              {value, label} <- [
                {"1", gettext("1 min")},
                {"3", gettext("3 min")},
                {"5", gettext("5 min")},
                {"10", gettext("10 min")},
                {"other", gettext("Other")}
              ]
            }
            class="cursor-pointer"
          >
            <input
              type="radio"
              name="settings[cooldown_choice]"
              value={value}
              checked={cooldown_choice(@current.cooldown_seconds) == value}
              class="peer sr-only"
            />
            <span class="flex h-9 items-center whitespace-nowrap rounded-full px-3 text-[0.8125rem] text-subtle peer-checked:bg-base-content peer-checked:font-semibold peer-checked:text-base-100">
              {label}
            </span>
          </label>
        </div>
        <label
          :if={cooldown_choice(@current.cooldown_seconds) == "other"}
          class="flex h-10 items-center gap-1.5 rounded-xl border border-(--inbox-field-line) bg-secondary px-3"
        >
          <input
            type="number"
            name="settings[cooldown_seconds]"
            min="0"
            max="3600"
            value={@current.cooldown_seconds}
            aria-label={gettext("Seconds between tickets")}
            class="w-14 border-0 bg-transparent p-0 text-right font-mono text-sm outline-none focus:ring-0"
          />
          <span class="text-[0.8125rem] text-muted">{gettext("seconds")}</span>
        </label>
        <span class="text-[0.8125rem] text-muted">
          {gettext("between one call and the next from the same player")}
        </span>
      </div>
      <div class="flex items-center gap-3 rounded-2xl bg-secondary px-3.5 py-3">
        <span class="flex-1 text-sm">{gettext("Tickets open at the same time per player")}</span>
        <div class="flex items-center gap-1 rounded-full border border-(--inbox-field-line) p-[3px]">
          <button
            type="button"
            phx-click="max_open"
            phx-value-delta="-1"
            aria-label={gettext("Decrease")}
            class="size-[1.875rem] cursor-pointer rounded-full text-base text-subtle hover:bg-base-300"
          >
            −
          </button>
          <span id="max-open" class="w-7 text-center font-mono text-sm">
            {@current.max_open_per_player}
          </span>
          <button
            type="button"
            phx-click="max_open"
            phx-value-delta="1"
            aria-label={gettext("Increase")}
            class="size-[1.875rem] cursor-pointer rounded-full text-base text-subtle hover:bg-base-300"
          >
            +
          </button>
        </div>
      </div>
    </div>

    <div class="flex flex-col gap-3">
      <span class="font-mono text-[0.6875rem] uppercase tracking-[0.1em] text-muted">
        {gettext("Who can use it")}
      </span>
      <div
        role="radiogroup"
        aria-label={gettext("Who can use it")}
        class="grid gap-2.5 sm:grid-cols-3"
      >
        <label
          :for={
            {value, title, hint} <- [
              {"all", gettext("Every player"), gettext("anyone on the server")},
              {"playtime", gettext("With playtime"),
               gettext("from %{hours} h on the server", hours: @current.min_playtime_hours)},
              {"vip", gettext("VIPs only"), gettext("exclusive support")}
            ]
          }
          class={[
            "flex cursor-pointer flex-col gap-1 rounded-[1.125rem] border p-3.5",
            if(@current.audience == value,
              do: "border-primary/50 bg-primary/8",
              else: "border-(--inbox-field-line) bg-secondary"
            )
          ]}
        >
          <input
            type="radio"
            name="settings[audience]"
            value={value}
            checked={@current.audience == value}
            class="sr-only"
          />
          <span class={[
            "flex items-center gap-2 text-sm",
            if(@current.audience == value, do: "font-semibold", else: "font-medium")
          ]}>
            <span class={[
              "size-4 shrink-0 rounded-full",
              if(@current.audience == value,
                do: "border-[5px] border-primary",
                else: "border-[1.5px] border-gray-600"
              )
            ]}></span>
            {title}
          </span>
          <span class={[
            "text-xs",
            if(@current.audience == value, do: "text-subtle", else: "text-muted")
          ]}>
            {hint}
          </span>
        </label>
      </div>
      <label
        :if={@current.audience == "playtime"}
        class="flex w-fit items-center gap-2 text-[0.8125rem] text-subtle"
      >
        {gettext("Minimum hours on the server")}
        <input
          type="number"
          name="settings[min_playtime_hours]"
          min="0"
          max="10000"
          value={@current.min_playtime_hours}
          class="h-9 w-20 rounded-xl border border-(--inbox-field-line) bg-secondary px-2.5 font-mono text-sm outline-none"
        />
      </label>
      <div class="flex flex-wrap items-center gap-2 text-[0.8125rem] text-subtle">
        <span class="mr-1">{gettext("Never accept from")}</span>
        <span
          :for={flag <- @blocked_flags}
          class="flex h-8 items-center gap-1.5 rounded-full border border-(--inbox-field-line) bg-secondary pl-3 pr-1 text-xs text-base-content"
        >
          {gettext("CRCON flag")} <span class="font-mono text-warning">{flag}</span>
          <button
            type="button"
            phx-click="remove_flag"
            phx-value-flag={flag}
            aria-label={gettext("Remove")}
            class="size-6 cursor-pointer rounded-full text-muted hover:text-base-content"
          >
            ×
          </button>
        </span>
        <span
          :if={@current.block_recent_bans}
          class="flex h-8 items-center gap-1.5 rounded-full border border-(--inbox-field-line) bg-secondary pl-3 pr-1 text-xs text-base-content"
        >
          {gettext("banned in the last 24 h")}
          <button
            type="button"
            phx-click="toggle_recent_bans"
            aria-label={gettext("Remove")}
            class="size-6 cursor-pointer rounded-full text-muted hover:text-base-content"
          >
            ×
          </button>
        </span>
        <button
          :if={!@adding_block?}
          type="button"
          phx-click="toggle_adding_block"
          class="h-8 cursor-pointer rounded-full border border-dashed border-(--inbox-strong) px-3 text-xs text-subtle"
        >
          + {gettext("block")}
        </button>
        <span :if={@adding_block?} class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            name="flag"
            form="flag-add"
            id={"flag-input-#{length(@blocked_flags)}"}
            placeholder={gettext("CRCON flag, e.g. no_ticket")}
            class="h-8 w-44 rounded-full border border-(--inbox-field-line) bg-secondary px-3 font-mono text-xs outline-none"
          />
          <button
            :if={!@current.block_recent_bans}
            type="button"
            phx-click="toggle_recent_bans"
            class="h-8 cursor-pointer rounded-full border border-(--inbox-field-line) bg-secondary px-3 text-xs"
          >
            + {gettext("banned in the last 24 h")}
          </button>
        </span>
      </div>
    </div>
    """
  end

  attr :current, :any, required: true
  attr :commands, :list, required: true
  attr :rows, :map, required: true
  attr :servers, :list, required: true

  defp review_step(assigns) do
    ~H"""
    <.step_heading
      title={gettext("Check and switch on")}
      text={
        gettext(
          "Players can call an admin as soon as you save. You can change everything later in the settings."
        )
      }
    />
    <dl id="wizard-review" class="grid gap-2.5 sm:grid-cols-2">
      <div class="rounded-2xl bg-secondary px-4 py-3 sm:col-span-2">
        <dt class="text-xs text-muted">{gettext("Servers")}</dt>
        <dd class="mt-0.5 font-medium">{Enum.map_join(@servers, ", ", & &1.name)}</dd>
      </div>
      <div class="rounded-2xl bg-secondary px-4 py-3">
        <dt class="text-xs text-muted">{gettext("Commands")}</dt>
        <dd class="mt-1 flex flex-wrap gap-1.5">
          <span
            :for={command <- @commands}
            class="inline-flex h-7 items-center rounded-full bg-primary/12 px-2.5 font-mono text-xs text-primary"
          >
            {command}
          </span>
        </dd>
      </div>
      <div class="rounded-2xl bg-secondary px-4 py-3">
        <dt class="text-xs text-muted">{gettext("Office hours")}</dt>
        <dd class="mt-0.5 font-medium">
          {if @current.hours_enabled,
            do: TicketSettingsForm.summary(@rows.hours),
            else: gettext("Any time")}
        </dd>
      </div>
      <div class="rounded-2xl bg-secondary px-4 py-3 sm:col-span-2">
        <dt class="text-xs text-muted">{gettext("Categories")}</dt>
        <dd class="mt-1 flex flex-wrap gap-1.5">
          <span :if={@rows.categories == []} class="font-medium">{gettext("None")}</span>
          <span
            :for={row <- @rows.categories}
            :if={row["name"] != ""}
            class={[
              "inline-flex h-7 items-center gap-1.5 rounded-full bg-base-300 px-2.5 text-xs",
              "inbox-color-#{row["color"]}"
            ]}
          >
            <span class="inbox-swatch size-2.5 rounded-[3px]"></span>
            {row["name"]}
          </span>
        </dd>
      </div>
    </dl>
    """
  end
end
