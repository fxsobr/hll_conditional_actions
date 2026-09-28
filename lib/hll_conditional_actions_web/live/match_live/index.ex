defmodule HllConditionalActionsWeb.MatchLive.Index do
  @moduledoc """
  The past matches of a server, from CRCON's match history.

  The list is fetched off the LiveView process: a CRCON that is slow to page
  through a long history leaves a skeleton on screen, not a frozen page.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_stats}}

  alias HllConditionalActions.Matches
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.MapArt

  @per_page 20

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Matches"))
     |> assign(:servers, Servers.list_servers_for(socket.assigns.current_user))
     |> assign(:per_page, @per_page)
     |> assign(:server, nil)
     |> assign(:page, 1)
     |> assign(:result, nil)
     |> assign(:error?, false)}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"server_id" => id} = params, _url, socket) do
    server = Enum.find(socket.assigns.servers, &(to_string(&1.id) == id))

    page =
      case Integer.parse(params["page"] || "1") do
        {page, ""} when page > 0 -> page
        _other -> 1
      end

    socket = assign(socket, server: server, page: page, result: nil, error?: false)

    socket =
      if server do
        start_async(socket, :matches, fn ->
          {server.id, Matches.list(server, page: page, limit: @per_page)}
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  # Matches are always a server's: the old address opens the first.
  def handle_params(_params, _url, socket) do
    case socket.assigns.servers do
      [server | _rest] -> {:noreply, push_navigate(socket, to: ~p"/servers/#{server}/matches")}
      [] -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/servers/#{socket.assigns.server}/matches?#{[page: page]}")}
  end

  @impl Phoenix.LiveView
  def handle_async(:matches, {:ok, {server_id, result}}, socket) do
    if socket.assigns.server && socket.assigns.server.id == server_id do
      case result do
        {:ok, result} -> {:noreply, assign(socket, result: result, error?: false)}
        {:error, _reason} -> {:noreply, assign(socket, :error?, true)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:matches, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :error?, true)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("Every match CRCON recorded, with its result and report")}
    >
      <.empty_state
        :if={@servers == []}
        icon="hero-flag"
        title={gettext("No server yet")}
        description={gettext("Connect a server and its match history shows up here.")}
      />

      <.empty_state
        :if={@error?}
        icon="hero-signal-slash"
        title={gettext("CRCON did not answer")}
        description={
          gettext(
            "The match history comes from CRCON. Check that the server is reachable and that its key may read scoreboards."
          )
        }
      />

      <div :if={@server && is_nil(@result) && not @error?} class="space-y-2">
        <.skeleton_block :for={_ <- 1..5} class="h-16 rounded-box" />
      </div>

      <.empty_state
        :if={@result && @result.matches == []}
        icon="hero-flag"
        title={gettext("No match recorded yet")}
        description={gettext("CRCON records a match when it ends.")}
      />

      <.card
        :if={@result && @result.matches != []}
        title={gettext("Matches on %{server}", server: @server.name)}
        icon="hero-flag"
        padded={false}
      >
        <ul id="matches" class="divide-y divide-base-300">
          <li :for={match <- @result.matches} id={"match-#{match.id}"}>
            <.link
              navigate={~p"/servers/#{@server}/matches/#{match.id}"}
              class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 transition-colors hover:bg-base-200/50 sm:px-5"
            >
              <img
                src={MapArt.url(@server.game, match.layer || match.map)}
                alt=""
                loading="lazy"
                class="h-11 w-16 shrink-0 rounded-field object-cover"
              />

              <span class="min-w-0 flex-1">
                <span class="block truncate font-medium">{match.map}</span>
                <span class="block truncate text-xs text-muted">
                  {mode_label(match.mode)} · {date(match.started_at)} · {duration(
                    match.duration_seconds
                  )}
                </span>
              </span>

              <.score allied={match.allied} axis={match.axis} winner={match.winner} />

              <.icon name="hero-chevron-right" class="size-4 text-muted" />
            </.link>
          </li>
        </ul>

        <.pagination page={@page} per_page={@per_page} total={@result.total} on_page="page" />
      </.card>
    </Layouts.app>
    """
  end

  @doc false
  attr :allied, :integer, default: nil
  attr :axis, :integer, default: nil
  attr :winner, :atom, default: nil

  def score(assigns) do
    ~H"""
    <span class="flex items-center gap-2 text-sm">
      <span class={["font-medium", @winner == :allies && "text-info"]}>{gettext("Allies")}</span>
      <span class="rounded-field bg-base-200 px-2 py-0.5 font-mono font-semibold tabular-nums">
        {@allied || "–"} : {@axis || "–"}
      </span>
      <span class={["font-medium", @winner == :axis && "text-error"]}>{gettext("Axis")}</span>
    </span>
    """
  end

  @doc false
  def mode_label(nil), do: gettext("Unknown mode")
  def mode_label(mode), do: mode |> to_string() |> String.capitalize()

  @doc false
  def date(nil), do: "–"
  def date(at), do: Calendar.strftime(at, "%d/%m/%Y %H:%M UTC")

  @doc false
  def duration(nil), do: "–"

  def duration(seconds) when seconds >= 3600,
    do: "#{div(seconds, 3600)}h#{pad(rem(seconds, 3600))}"

  def duration(seconds), do: "#{div(seconds, 60)} min"

  defp pad(seconds), do: seconds |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
end
