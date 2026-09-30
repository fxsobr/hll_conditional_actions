defmodule HllConditionalActionsWeb.SeasonLive.Show do
  @moduledoc """
  One season, drawn like the seasons page draws the running one
  (`SeasonLive.Dashboard`): hero, podium, standings, formula and what
  happens when it closes - or what happened, once it closed. An admin can
  change it (`/seasons/:id/edit`, the form of `SeasonLive.Form`), close it early or
  remove it.
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
  def mount(%{"id" => id}, _session, socket) do
    season = Progression.get_season!(id)
    servers = Servers.list_servers_for(socket.assigns.current_user)

    # Reaching any server of the season is enough to see it.
    reachable = MapSet.new(servers, & &1.id)

    if Enum.any?(season.servers, &MapSet.member?(reachable, &1.id)) do
      {:ok,
       socket
       |> assign(:page_title, season.name)
       |> assign(:all_servers, servers)
       |> assign(search: "", all?: false, form: nil)
       |> load(season)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/seasons")}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    # `?edit` is the older address of the edit route; it still opens the form.
    editing? = socket.assigns.live_action == :edit or Map.has_key?(params, "edit")

    if editing? and manage?(socket) and socket.assigns[:data] do
      season = socket.assigns.data.season

      {:noreply,
       Form.open(socket, season, socket.assigns.all_servers, Enum.map(season.servers, & &1.id))}
    else
      {:noreply, assign(socket, :form, nil)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(event, params, socket)
      when event in ~w(validate save step add_metric remove_metric rating_preset) do
    if manage?(socket), do: Form.handle_event(event, params, socket), else: {:noreply, socket}
  end

  def handle_event("search_standings", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :search, q)}

  def handle_event("standings_all", _params, socket), do: {:noreply, assign(socket, :all?, true)}

  def handle_event("finish", _params, socket) do
    if manage?(socket) do
      season = Progression.finalize_season(socket.assigns.data.season)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Season closed and the winners rewarded."))
       |> load(season)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    if manage?(socket) do
      {:ok, _season} = Progression.delete_season(socket.assigns.data.season)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Season removed."))
       |> push_navigate(to: ~p"/seasons")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_async({:preview, _server_id} = name, result, socket),
    do: Form.handle_async(name, result, socket)

  defp load(socket, season) do
    season = Progression.get_season!(season.id)
    assign(socket, :data, Dashboard.data(season))
  end

  defp manage?(socket), do: Accounts.can?(socket.assigns.current_user, :manage_progression)

  @impl Phoenix.LiveView
  def render(%{form: form} = assigns) when form != nil do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Edit season")}
      crumb={gettext("Community / Seasons · %{name}", name: @data.season.name)}
      back={~p"/seasons/#{@data.season.id}"}
      back_label={gettext("Back to the season")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.pill_button patch={~p"/seasons/#{@data.season.id}"} class="max-sm:hidden">
          {gettext("Cancel")}
        </.pill_button>
        <.pill_button
          id="season-submit"
          type="submit"
          form="season-form"
          primary
          phx-disable-with={gettext("Saving...")}
        >
          {gettext("Save season")}
        </.pill_button>
      </:actions>

      <Form.form_page
        form={@form}
        params={@params}
        preview={@preview}
        current={@current}
        servers={@all_servers}
        editing={@editing}
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
      page_title={@data.season.name}
      crumb={gettext("Community / Seasons")}
      back={~p"/seasons"}
      back_label={gettext("Back to Seasons")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.pill_button
          :if={Accounts.can?(@current_user, :manage_progression)}
          id="season-edit"
          patch={~p"/seasons/#{@data.season.id}/edit"}
          icon="hero-pencil-square"
        >
          <span class="max-md:sr-only">{gettext("Edit")}</span>
        </.pill_button>
        <.pill_button
          :if={@data.season.status == :active and Accounts.can?(@current_user, :manage_progression)}
          id="season-finish"
          type="button"
          icon="hero-flag"
          phx-click="finish"
          data-confirm={gettext("Close the season now and reward the current top players?")}
          class="max-md:hidden"
        >
          {gettext("Close now")}
        </.pill_button>
        <.pill_button
          :if={Accounts.can?(@current_user, :manage_progression)}
          id="season-delete"
          type="button"
          icon="hero-trash"
          phx-click="delete"
          aria-label={gettext("Remove")}
          data-confirm={gettext("Remove this season and its standings?")}
          class="!px-3.5 text-error"
        >
          <span class="sr-only">{gettext("Remove")}</span>
        </.pill_button>
      </:actions>

      <Dashboard.dashboard data={@data} search={@search} all?={@all?} now={@now} />
    </Layouts.app>
    """
  end
end
