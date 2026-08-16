defmodule HllConditionalActionsWeb.ExecutionLive.Index do
  @moduledoc """
  The audit log: every time a rule fired, for whom, and what each of its
  actions did.

  New executions arrive live over PubSub, so an admin watching this page sees a
  rule take effect the moment it does — but only on the first page. Reloading
  page four because something happened on page one would move the row somebody
  is reading out from under their cursor, so past the first page the list holds
  still until they ask for it.
  """

  use HllConditionalActionsWeb, :live_view

  # Enforced server side on mount; the sidebar merely hides the link.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  alias HllConditionalActions.Engine
  alias HllConditionalActions.Rules
  alias HllConditionalActions.Servers

  # Enough that a quiet server needs no paging at all, small enough that the
  # page stays quick on a busy one.
  @per_page 50

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns[:current_user])

    if connected?(socket), do: Enum.each(servers, &Engine.subscribe(&1.id))

    {:ok,
     socket
     |> assign(:page_title, gettext("History"))
     |> assign(:servers, servers)
     |> assign(:filters, %{server_id: nil, status: nil, player_id: nil})
     |> assign(:expanded, MapSet.new())
     |> assign(:page, 1)
     |> assign(:per_page, @per_page)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters = %{
      server_id: blank_to_nil(params["server_id"]),
      status: cast_status(params["status"]),
      player_id: blank_to_nil(params["player_id"])
    }

    # Narrowing the filters while on page 6 would otherwise land on a page
    # that no longer exists.
    {:noreply, socket |> assign(:filters, filters) |> assign(:page, 1) |> load()}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, cast_page(page)) |> load()}
  end

  def handle_event("toggle_details", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :expanded, fn expanded ->
       if MapSet.member?(expanded, id) do
         MapSet.delete(expanded, id)
       else
         MapSet.put(expanded, id)
       end
     end)}
  end

  @impl Phoenix.LiveView
  def handle_info({:rule_fired, _execution}, %{assigns: %{page: 1}} = socket) do
    {:noreply, load(socket)}
  end

  def handle_info({:rule_fired, _execution}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    user = socket.assigns[:current_user]
    filters = Enum.to_list(socket.assigns.filters)
    total = Rules.count_executions_for(user, filters)

    # A page emptied by rows expiring or by a narrower filter would otherwise
    # show nothing at all; walk back to the last page that has rows.
    page = min(socket.assigns.page, max(ceil(total / @per_page), 1))

    executions =
      Rules.list_executions_for(
        user,
        filters ++ [limit: @per_page, offset: (page - 1) * @per_page]
      )

    socket
    |> assign(:executions, executions)
    |> assign(:total, total)
    |> assign(:page, page)
  end

  defp cast_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, _rest} when number > 0 -> number
      _other -> 1
    end
  end

  defp cast_page(_page), do: 1

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp cast_status(status) when status in ~w(executed partial failed simulated) do
    String.to_existing_atom(status)
  end

  defp cast_status(_status), do: nil

  defp status_tone(:executed), do: "success"
  defp status_tone(:partial), do: "warning"
  defp status_tone(:failed), do: "error"
  defp status_tone(:simulated), do: "info"
  defp status_tone(_status), do: "ghost"

  # The stored trigger is a string; show the same translated label the rule
  # builder uses, falling back to the raw value for anything unknown.
  defp trigger_label(trigger) when is_atom(trigger), do: Labels.trigger(trigger)

  defp trigger_label(trigger) when is_binary(trigger) do
    Labels.trigger(String.to_existing_atom(trigger))
  rescue
    ArgumentError -> trigger
    FunctionClauseError -> trigger
  end

  defp result_class("ok"), do: "text-success"
  defp result_class("skipped"), do: "opacity-60"
  defp result_class("simulated"), do: "text-info"
  defp result_class(_status), do: "text-error"

  defp action_label(type) do
    Labels.action(String.to_existing_atom(type))
  rescue
    ArgumentError -> type
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("History")}
      page_subtitle={gettext("Every time a rule fired, and what it did")}
    >
      <.filter_bar id="execution-filters" on_change="filter">
        <.filter_select
          name="server_id"
          label={gettext("Server")}
          value={@filters.server_id}
          prompt={gettext("Every server")}
          options={Enum.map(@servers, &{&1.name, &1.id})}
        />
        <.filter_select
          name="status"
          label={gettext("Outcome")}
          value={@filters.status}
          prompt={gettext("Any outcome")}
          options={
            Enum.map(
              ~w(executed partial failed simulated)a,
              &{Labels.execution_status(&1), to_string(&1)}
            )
          }
        />

        <label class="max-sm:grow">
          <span class="sr-only">{gettext("Player ID")}</span>
          <input
            type="text"
            name="player_id"
            value={@filters.player_id}
            placeholder={gettext("Player ID")}
            class="pc-text-input w-full sm:w-52"
            phx-debounce="400"
          />
        </label>
      </.filter_bar>

      <.empty_state
        :if={@executions == []}
        icon="hero-clock"
        title={gettext("No rule executions recorded yet.")}
        description={
          gettext("Every time a rule fires it is recorded here, with what each of its actions did.")
        }
      />

      <.card :if={@executions != []} padded={false}>
        <table class="table-collapse app-table">
          <thead class="text-xs uppercase tracking-wide text-muted">
            <tr>
              <th>{gettext("When")}</th>

              <th>{gettext("Rule")}</th>

              <th>{gettext("Player")}</th>

              <th>{gettext("Server")}</th>

              <th>{gettext("Outcome")}</th>

              <th class="w-0 text-right">
                <span class="sr-only">{gettext("Actions")}</span>
              </th>
            </tr>
          </thead>

          <tbody class="divide-y divide-base-300">
            <%= for execution <- @executions do %>
              <tr class="sm:hover:bg-base-200/60">
                <td data-cell="lead" class="whitespace-nowrap text-sm text-subtle">
                  <.local_time id={"execution-#{execution.id}-at"} at={execution.executed_at} />
                </td>

                <td data-label={gettext("Rule")}>
                  <.link
                    navigate={~p"/rules/#{execution.rule_id}"}
                    class="text-sm font-medium hover:underline"
                  >
                    {execution.rule.name}
                  </.link>

                  <p class="text-xs text-muted max-sm:hidden">
                    {trigger_label(execution.trigger_event)}
                  </p>
                </td>

                <td data-label={gettext("Player")} class="text-sm">
                  <.link
                    :if={execution.player_id}
                    navigate={~p"/players/#{execution.player_id}"}
                    class="font-medium hover:text-primary hover:underline"
                  >
                    {execution.player_name || execution.player_id}
                  </.link>

                  <span :if={is_nil(execution.player_id)} class="text-muted">
                    {gettext("server wide")}
                  </span>
                </td>

                <td data-label={gettext("Server")} class="text-sm text-subtle">
                  {execution.server.name}
                </td>

                <td data-label={gettext("Outcome")}>
                  <.tone_badge tone={status_tone(execution.status)}>
                    {Labels.execution_status(execution.status)}
                  </.tone_badge>
                </td>

                <td data-cell="actions" class="text-right">
                  <.button
                    :if={execution.results != []}
                    type="button"
                    size="xs"
                    variant="ghost"
                    color="gray"
                    icon={
                      if MapSet.member?(@expanded, to_string(execution.id)),
                        do: "hero-chevron-up",
                        else: "hero-chevron-down"
                    }
                    icon_placement="right"
                    phx-click="toggle_details"
                    phx-value-id={execution.id}
                    aria-expanded={to_string(MapSet.member?(@expanded, to_string(execution.id)))}
                    label={gettext("Details")}
                  />
                </td>
              </tr>

              <tr :if={MapSet.member?(@expanded, to_string(execution.id))} class="bg-base-200/60">
                <td colspan="6">
                  <ul class="space-y-1 py-2 text-sm">
                    <li :for={result <- execution.results} class="flex flex-wrap gap-x-2">
                      <span class={["font-medium", result_class(result["status"])]}>
                        {action_label(result["type"])}
                      </span>
                      <span class="text-subtle">{result["detail"]}</span>
                    </li>
                  </ul>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <.pagination page={@page} per_page={@per_page} total={@total} on_page="page" />
      </.card>
    </Layouts.app>
    """
  end
end
