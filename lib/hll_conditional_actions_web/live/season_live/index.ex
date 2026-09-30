defmodule HllConditionalActionsWeb.SeasonLive.Index do
  @moduledoc """
  Seasons: leaderboards over a stretch of time whose top players are
  rewarded when it ends. The page opens on the running season - its hero,
  podium, standings, formula and what happens when it closes (see
  `SeasonLive.Dashboard`) - with the earlier ones a click away; `/seasons/new`
  is the form (`SeasonLive.Form`).

  A season runs on the servers the admin picks - one, or several of the
  same game. Under `/servers/:id/seasons` the page shows that server's
  seasons. Each match adds to the season and
  `HllConditionalActions.Workers.FinalizeSeasons` closes it.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  import HllConditionalActionsWeb.CommunityComponents

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.SeasonLive.Dashboard
  alias HllConditionalActionsWeb.SeasonLive.Form

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    all = Servers.list_servers_for(socket.assigns.current_user)
    scope = Enum.find(all, &(to_string(&1.id) == params["server_id"]))

    {:ok,
     socket
     |> assign(:page_title, gettext("Community"))
     |> assign(:scope, scope)
     |> assign(:servers, if(scope, do: [scope], else: all))
     # A new season can take any server the user reaches, not only the one
     # whose page this is: that is how a season spans servers.
     |> assign(:all_servers, all)
     |> assign(search: "", all?: false, past?: false, data: nil, seasons: [], form: nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    if Accounts.can?(socket.assigns.current_user, :manage_progression) and
         socket.assigns.all_servers != [] do
      first = List.first(socket.assigns.servers) || List.first(socket.assigns.all_servers)

      socket
      |> assign(:page_title, gettext("New season"))
      |> Form.open(nil, socket.assigns.all_servers, [first.id])
    else
      push_patch(socket, to: ~p"/seasons")
    end
  end

  defp apply_action(socket, _index, params) do
    seasons = Progression.list_seasons(Enum.map(socket.assigns.servers, & &1.id))

    season =
      Enum.find(seasons, &(to_string(&1.id) == params["season"])) ||
        Enum.find(seasons, &(&1.status == :active)) || List.first(seasons)

    socket
    |> assign(:page_title, gettext("Community"))
    |> assign(:form, nil)
    |> assign(:seasons, seasons)
    |> assign(:data, season && Dashboard.data(season))
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket)
      when event in ~w(validate save step add_metric remove_metric rating_preset),
      do: Form.handle_event(event, params, socket)

  def handle_event("search_standings", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :search, q)}

  def handle_event("standings_all", _params, socket), do: {:noreply, assign(socket, :all?, true)}
  def handle_event("open_past", _params, socket), do: {:noreply, assign(socket, :past?, true)}
  def handle_event("close_past", _params, socket), do: {:noreply, assign(socket, :past?, false)}

  @impl Phoenix.LiveView
  def handle_async({:preview, _server_id} = name, result, socket),
    do: Form.handle_async(name, result, socket)

  @impl Phoenix.LiveView
  def render(%{live_action: :new, form: form} = assigns) when form != nil do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("New season")}
      crumb={Form.crumb(@current)}
      back={~p"/seasons"}
      back_label={gettext("Back to Seasons")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.pill_button navigate={~p"/seasons"} class="max-sm:hidden">{gettext("Cancel")}</.pill_button>
        <.pill_button
          id="season-submit"
          type="submit"
          form="season-form"
          primary
          phx-disable-with={gettext("Saving...")}
        >
          {gettext("Create season")}
        </.pill_button>
      </:actions>

      <Form.form_page
        form={@form}
        params={@params}
        preview={@preview}
        current={@current}
        servers={@all_servers}
      />
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
    >
      <:actions>
        <.pill_button
          :if={@seasons != []}
          id="past-seasons"
          type="button"
          phx-click="open_past"
          class="max-md:hidden"
        >
          {gettext("Earlier seasons")}
        </.pill_button>
        <.pill_button
          :if={Accounts.can?(@current_user, :manage_progression) and @all_servers != []}
          id="new-season"
          navigate={~p"/seasons/new"}
          primary
          icon="hero-plus"
        >
          {gettext("New season")}
        </.pill_button>
      </:actions>

      <.empty_state
        :if={@seasons == []}
        icon="hero-trophy"
        title={gettext("No season yet")}
        description={
          gettext(
            "A season adds up the matches of a few weeks - teamplay, kills, support, or a formula of your own - and gives VIP to the best when it closes. It can open the next one on its own."
          )
        }
      >
        <:action :if={Accounts.can?(@current_user, :manage_progression) and @all_servers != []}>
          <.pill_button navigate={~p"/seasons/new"} primary icon="hero-plus">
            {gettext("New season")}
          </.pill_button>
        </:action>
      </.empty_state>

      <.link
        :if={@data && @data.season.status == :active}
        navigate={~p"/seasons/#{@data.season.id}"}
        class="sr-only"
      >
        {gettext("Open %{name}", name: @data.season.name)}
      </.link>

      <Dashboard.dashboard :if={@data} data={@data} search={@search} all?={@all?} now={@now} />

      <div :if={@seasons != []} class="md:hidden">
        <button type="button" phx-click="open_past" class="com-pill w-full justify-center">
          {gettext("Earlier seasons")}
        </button>
      </div>

      <.modal
        :if={@past?}
        id="past-seasons-modal"
        title={gettext("All seasons")}
        on_cancel={JS.push("close_past")}
      >
        <ul id="seasons" class="flex flex-col gap-1">
          <li :for={season <- @seasons} id={"season-#{season.id}"}>
            <.link
              navigate={~p"/seasons/#{season.id}"}
              class="flex items-center gap-3 rounded-2xl px-3 py-2.5 transition-colors hover:bg-secondary"
            >
              <span class="flex min-w-0 flex-1 flex-col">
                <strong class="truncate text-sm font-semibold">{season.name}</strong>
                <span class="truncate text-xs text-muted">
                  {Dashboard.servers_line(season.servers)} · {short_date(
                    DateTime.to_date(season.starts_at)
                  )} – {short_date(DateTime.to_date(season.finished_at || season.ends_at))}
                </span>
              </span>
              <.pill tone={if season.status == :active, do: "live", else: "neutral"}>
                {if season.status == :active, do: gettext("Running"), else: gettext("Finished")}
              </.pill>
            </.link>
          </li>
        </ul>
      </.modal>
    </Layouts.app>
    """
  end
end
