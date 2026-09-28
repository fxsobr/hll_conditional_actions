defmodule HllConditionalActionsWeb.TicketLive.Setup do
  @moduledoc """
  The ticket setup wizard: the few choices that matter to get tickets
  working, one per step, with the in-game preview of every message.

    1. servers - only from `/tickets/setup`, where nothing picks one
    2. commands - what players type
    3. categories - optional
    4. messages - what the player reads
    5. office hours - optional
    6. review - a summary, and switching tickets on

  Everything else (limits, quick replies, Discord) keeps its sensible
  default and lives in the settings page. The steps share one form, so
  going back and forth keeps what was typed; each "Next" checks only the
  fields of the step it leaves. Nothing is saved before the last step.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_tickets}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActionsWeb.TicketSettingsForm

  @form_steps [:general, :categories, :messages, :schedule]

  @impl Phoenix.LiveView
  def mount(%{"server_id" => server_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, server} <- Servers.fetch_server(server_id),
         true <- Accounts.can_access_server?(user, server) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Set up tickets"))
       |> assign(:server, server)
       |> assign(:servers, [server])
       |> assign(:selected, [server.id])
       |> assign(:steps, @form_steps ++ [:review])
       |> assign(:step, :general)
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

    socket =
      socket
      |> assign(:page_title, gettext("Set up tickets"))
      |> assign(:server, nil)
      |> assign(:servers, servers)
      |> assign(:selected, first)
      |> assign(:steps, [:servers | @form_steps] ++ [:review])
      |> assign(:step, :servers)

    {:ok, load_base(socket, List.first(first))}
  end

  # The wizard starts from what the (first) server has, or the defaults.
  defp load_base(socket, nil) do
    settings = TicketSettingsForm.defaults(%Settings{enabled: true})

    socket
    |> assign(:settings, settings)
    |> TicketSettingsForm.assign_form(Tickets.change_settings(settings))
  end

  defp load_base(socket, server_id) do
    settings =
      case Tickets.get_settings(server_id) do
        %Settings{id: nil} = fresh -> TicketSettingsForm.defaults(%{fresh | enabled: true})
        saved -> saved
      end

    socket
    |> assign(:settings, settings)
    |> TicketSettingsForm.assign_form(Tickets.change_settings(settings))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"settings" => params}, socket) do
    changeset =
      socket.assigns.settings
      |> Tickets.change_settings(TicketSettingsForm.parse(params))
      |> Map.put(:action, socket.assigns.form.source.action)

    {:noreply,
     socket
     |> TicketSettingsForm.assign_form(changeset)
     |> assign(:category_rows, TicketSettingsForm.rows(params))}
  end

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

  def handle_event("add_category", _params, socket) do
    rows = socket.assigns.category_rows ++ [%{"name" => "", "priority" => "normal"}]
    {:noreply, assign(socket, :category_rows, rows)}
  end

  def handle_event("remove_category", %{"index" => index}, socket) do
    rows = List.delete_at(socket.assigns.category_rows, String.to_integer(index))
    {:noreply, assign(socket, :category_rows, rows)}
  end

  def handle_event("back", _params, socket), do: {:noreply, move(socket, -1)}

  def handle_event("next", _params, %{assigns: %{step: :servers, selected: []}} = socket),
    do: {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

  def handle_event("next", _params, socket) do
    step = socket.assigns.step
    changeset = Map.put(socket.assigns.form.source, :action, :validate)

    # Only the fields of the step being left are held against it.
    step_errors? =
      step in @form_steps and
        Enum.any?(changeset.errors, fn {field, _} -> field in TicketSettingsForm.fields(step) end)

    if step_errors? do
      {:noreply, TicketSettingsForm.assign_form(socket, changeset)}
    else
      {:noreply, move(socket, 1)}
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

  def handle_event("finish", %{"settings" => params}, socket) do
    params = TicketSettingsForm.parse(params)
    changeset = Tickets.change_settings(socket.assigns.settings, params)

    cond do
      socket.assigns.selected == [] ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one server."))}

      not changeset.valid? ->
        {:noreply,
         socket
         |> TicketSettingsForm.assign_form(Map.put(changeset, :action, :validate))
         |> put_flash(:error, gettext("Something needs fixing: see the highlighted step."))
         |> assign(:step, first_step_with_errors(changeset))}

      true ->
        Enum.each(socket.assigns.selected, fn id ->
          {:ok, _saved} = Tickets.save_settings(Tickets.get_settings(id), params)
        end)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Tickets are set up. Players can call an admin now."))
         |> push_navigate(to: done_path(socket))}
    end
  end

  defp first_step_with_errors(changeset) do
    Enum.find(@form_steps, :general, fn step ->
      Enum.any?(changeset.errors, fn {field, _} -> field in TicketSettingsForm.fields(step) end)
    end)
  end

  defp done_path(%{assigns: %{server: nil}}), do: ~p"/tickets"
  defp done_path(%{assigns: %{server: server}}), do: ~p"/servers/#{server.id}/tickets"

  defp move(socket, delta) do
    steps = socket.assigns.steps
    next = Enum.at(steps, max(0, index(steps, socket.assigns.step) + delta))
    assign(socket, :step, next || socket.assigns.step)
  end

  defp index(steps, step), do: Enum.find_index(steps, &(&1 == step))

  defp step_title(:servers), do: gettext("Servers")
  defp step_title(:review), do: gettext("Review")
  defp step_title(step), do: TicketSettingsForm.title(step)

  defp step_hint(:servers), do: gettext("Which servers take tickets")
  defp step_hint(:review), do: gettext("Check and switch tickets on")
  defp step_hint(step), do: TicketSettingsForm.hint(step)

  defp step_icon(:servers), do: "hero-server-stack"
  defp step_icon(:review), do: "hero-check-badge"
  defp step_icon(step), do: TicketSettingsForm.icon_name(step)

  defp time(nil), do: "–"
  defp time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp time(text), do: text

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :position, index(assigns.steps, assigns.step))

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
          to={
            if @server, do: ~p"/servers/#{@server.id}/tickets/settings", else: ~p"/tickets/settings"
          }
          size="sm"
          variant="ghost"
          color="gray"
          label={gettext("Skip to all settings")}
        />
      </:actions>

      <div class="mx-auto w-full max-w-3xl space-y-4">
        <ol
          id="wizard-steps"
          class="flex items-center gap-1 overflow-x-auto pb-1"
          aria-label={gettext("Steps")}
        >
          <li :for={{step, index} <- Enum.with_index(@steps)} class="flex shrink-0 items-center gap-1">
            <button
              type="button"
              phx-click="goto"
              phx-value-step={step}
              disabled={index >= @position}
              aria-current={step == @step && "step"}
              class={[
                "flex items-center gap-2 rounded-full px-3 py-1.5 text-sm transition-colors",
                step == @step && "bg-primary font-medium text-primary-content",
                index < @position && "cursor-pointer bg-primary/10 text-primary hover:bg-primary/20",
                index > @position && "text-muted"
              ]}
            >
              <span class={[
                "flex size-5 items-center justify-center rounded-full text-xs font-semibold",
                step == @step && "bg-primary-content/20",
                index < @position && "bg-primary/20",
                index > @position && "border border-base-300"
              ]}>
                <.icon :if={index < @position} name="hero-check" class="size-3" />
                <span :if={index >= @position}>{index + 1}</span>
              </span>
              <span class={[step != @step && "max-sm:hidden"]}>{step_title(step)}</span>
            </button>
            <span :if={index < length(@steps) - 1} class="h-px w-4 bg-base-300" aria-hidden="true"></span>
          </li>
        </ol>

        <.card>
          <header class="flex items-start gap-3 border-b border-base-300 pb-4">
            <span class="flex size-10 shrink-0 items-center justify-center rounded-field bg-primary/10 text-primary">
              <.icon name={step_icon(@step)} class="size-5" />
            </span>
            <div>
              <p class="text-label-small text-muted">
                {gettext("Step %{current} of %{total}", current: @position + 1, total: length(@steps))}
              </p>
              <h2 class="text-title-large" id="wizard-title">{step_title(@step)}</h2>
              <p class="text-sm text-muted">{step_hint(@step)}</p>
            </div>
          </header>

          <form
            :if={@step == :servers}
            id="server-picker"
            phx-change="select_servers"
            class="grid gap-2 sm:grid-cols-2"
          >
            <input type="hidden" name="server_ids[]" value="" />
            <label
              :for={server <- @servers}
              class="flex cursor-pointer items-center gap-2 rounded-field border border-base-300 px-3 py-2.5 transition-colors hover:bg-base-200/60 has-[:checked]:border-primary/50 has-[:checked]:bg-primary/5"
            >
              <input
                type="checkbox"
                name="server_ids[]"
                value={server.id}
                checked={server.id in @selected}
                class="pc-checkbox"
              />
              <span class="truncate font-medium">{server.name}</span>
            </label>
            <p :if={@servers == []} class="text-sm text-muted">
              {gettext("You have no server yet.")}
            </p>
          </form>

          <.form for={@form} id="wizard-form" phx-change="validate" phx-submit="finish">
            <TicketSettingsForm.section
              :for={name <- [:general, :categories, :messages, :schedule]}
              name={name}
              visible={name == @step}
              show_header={false}
              form={@form}
              commands={@commands}
              commands_text={@commands_text}
              quick_replies_text={@quick_replies_text}
              category_rows={@category_rows}
              hours_days={@hours_days}
              admin_name={@current_user.name || @current_user.username}
              multi?={length(@selected) > 1}
            />

            <div :if={@step == :review} id="wizard-review" class="space-y-4">
              <dl class="divide-y divide-base-300 text-sm">
                <div class="flex justify-between gap-4 py-2">
                  <dt class="text-muted">{gettext("Servers")}</dt>
                  <dd class="text-right">
                    {@servers |> Enum.filter(&(&1.id in @selected)) |> Enum.map_join(", ", & &1.name)}
                  </dd>
                </div>
                <div class="flex justify-between gap-4 py-2">
                  <dt class="text-muted">{gettext("Commands")}</dt>
                  <dd class="flex flex-wrap justify-end gap-1">
                    <.tone_badge :for={command <- @commands} tone="primary">{command}</.tone_badge>
                  </dd>
                </div>
                <div class="flex justify-between gap-4 py-2">
                  <dt class="text-muted">{gettext("Categories")}</dt>
                  <dd class="flex flex-wrap justify-end gap-1">
                    <span :if={@category_rows == []}>{gettext("None")}</span>
                    <.tone_badge
                      :for={row <- @category_rows}
                      :if={row["name"] != ""}
                      tone={
                        Labels.ticket_priority_tone(
                          HllConditionalActions.Tickets.Ticket.parse_priority(row["priority"])
                        )
                      }
                    >
                      {row["name"]} · {Labels.ticket_priority(
                        HllConditionalActions.Tickets.Ticket.parse_priority(row["priority"])
                      )}
                    </.tone_badge>
                  </dd>
                </div>
                <div class="flex justify-between gap-4 py-2">
                  <dt class="text-muted">{gettext("Office hours")}</dt>
                  <dd :if={@form[:hours_enabled].value in [true, "true"]}>
                    {time(@form[:hours_start].value)} – {time(@form[:hours_end].value)}
                  </dd>
                  <dd :if={@form[:hours_enabled].value not in [true, "true"]}>
                    {gettext("Any time")}
                  </dd>
                </div>
              </dl>

              <TicketSettingsForm.game_message
                :if={
                  is_binary(@form[:received_message].value) and @form[:received_message].value != ""
                }
                id="review-preview"
                text={
                  TicketSettingsForm.sample(
                    @form[:received_message].value,
                    @commands,
                    @current_user.name || @current_user.username
                  )
                }
              />

              <p class="rounded-box bg-base-200/60 p-3 text-sm text-muted">
                {gettext(
                  "Limits, quick replies and the Discord announcement start with sensible defaults. Change them later in the settings."
                )}
              </p>
            </div>

            <footer class="mt-6 flex items-center justify-between gap-3 border-t border-base-300 pt-4">
              <.button
                :if={@position > 0}
                type="button"
                phx-click="back"
                size="sm"
                variant="ghost"
                color="gray"
                icon="hero-arrow-left"
                label={gettext("Back")}
              />
              <span :if={@position == 0}></span>
              <.button
                :if={@step != :review}
                type="button"
                phx-click="next"
                size="sm"
                color="primary"
                label={gettext("Next")}
              />
              <.button
                :if={@step == :review}
                type="submit"
                size="sm"
                color="primary"
                icon="hero-check"
                phx-disable-with={gettext("Saving...")}
                label={gettext("Save and turn on")}
              />
            </footer>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
