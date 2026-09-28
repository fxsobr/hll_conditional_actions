defmodule HllConditionalActionsWeb.SeasonLive.Show do
  @moduledoc """
  One season: its standings, who is in line for the reward, and - once it
  closed - who won. An admin can close it early or remove it.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  import HllConditionalActionsWeb.SeasonLive.Index, only: [days_left: 2, elapsed: 2, vip_label: 1]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.RatingComponents

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    season = Progression.get_season!(id)

    # Reaching any server of the season is enough to see it.
    reachable = socket.assigns.current_user |> Servers.list_servers_for() |> MapSet.new(& &1.id)

    if Enum.any?(season.servers, &MapSet.member?(reachable, &1.id)) do
      {:ok, socket |> assign(:page_title, season.name) |> load(season)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/seasons")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("finish", _params, socket) do
    if manage?(socket) do
      season = Progression.finalize_season(socket.assigns.season)

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
      {:ok, _season} = Progression.delete_season(socket.assigns.season)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Season removed."))
       |> push_navigate(to: ~p"/seasons")}
    else
      {:noreply, socket}
    end
  end

  defp load(socket, season) do
    season = Progression.get_season!(season.id)

    socket
    |> assign(:season, season)
    |> assign(:rating, Rating.normalize(season.rating))
    |> assign(:standings, Progression.standings(season))
  end

  defp manage?(socket), do: Accounts.can?(socket.assigns.current_user, :manage_progression)

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assign(assigns,
        now: DateTime.utc_now(),
        qualified: Enum.filter(assigns.standings, & &1.qualified)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@season.name}
      page_subtitle={"#{Enum.map_join(@season.servers, ", ", & &1.name)} · #{Labels.scoring(@season.scoring)}"}
    >
      <:actions>
        <.button
          link_type="live_redirect"
          to={~p"/seasons"}
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-left"
        >
          <span class="hidden sm:inline">{gettext("All seasons")}</span>
        </.button>
        <.button
          :if={@season.status == :active and Accounts.can?(@current_user, :manage_progression)}
          type="button"
          size="sm"
          variant="outline"
          color="gray"
          icon="hero-flag"
          phx-click="finish"
          data-confirm={gettext("Close the season now and reward the current top players?")}
          label={gettext("Close now")}
        />
        <.button
          :if={Accounts.can?(@current_user, :manage_progression)}
          type="button"
          size="sm"
          variant="ghost"
          color="danger"
          icon="hero-trash"
          phx-click="delete"
          data-confirm={gettext("Remove this season and its standings?")}
        />
      </:actions>

      <div id="season-kpis" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat
          icon="hero-calendar-days"
          tone={if @season.status == :active, do: "success", else: "neutral"}
          label={gettext("Status")}
          value={
            if @season.status == :active,
              do: days_left(@season, @now),
              else: gettext("Finished")
          }
          hint={
            "#{Calendar.strftime(@season.starts_at, "%d/%m/%Y")} – #{Calendar.strftime(@season.ends_at, "%d/%m/%Y")}"
          }
        />
        <.stat
          icon="hero-users"
          label={gettext("Players")}
          value={length(@standings)}
          hint={ngettext("1 qualified", "%{count} qualified", length(@qualified))}
        />
        <.stat
          icon="hero-trophy"
          tone="warning"
          label={gettext("Winners")}
          value={@season.winners_count}
          hint={
            ngettext(
              "at least 1 match to qualify",
              "at least %{count} matches to qualify",
              @season.min_matches
            )
          }
        />
        <.stat
          icon="hero-gift"
          tone="primary"
          label={gettext("Reward")}
          value={
            if @season.reward_vip_hours > 0,
              do: gettext("VIP %{duration}", duration: vip_label(@season.reward_vip_hours)),
              else: "–"
          }
          hint={if @season.auto_renew, do: gettext("the next season starts on its own")}
        />
      </div>

      <div :if={@season.status == :active} class="h-2 overflow-hidden rounded-pill bg-base-300">
        <div class="h-full rounded-pill bg-primary" style={"width: #{elapsed(@season, @now)}%"}></div>
      </div>

      <div class={["grid gap-4", @season.scoring == :elo && "xl:grid-cols-3"]}>
        <.card
          title={gettext("Standings")}
          icon="hero-trophy"
          padded={false}
          id="season-standings"
          class={@season.scoring == :elo && "xl:col-span-2"}
        >
          <p :if={@standings == []} class="px-5 py-8 text-center text-sm text-muted">
            {gettext("Nobody has scored yet: every match that ends on the server adds to the season.")}
          </p>
          <table :if={@standings != []} class="w-full text-sm">
            <thead class="text-left text-xs tracking-wide text-muted uppercase">
              <tr class="border-b border-base-300">
                <th class="w-12 px-4 py-2 font-medium sm:px-5">#</th>
                <th class="px-2 py-2 font-medium">{gettext("Player")}</th>
                <th class="px-2 py-2 text-right font-medium">{Labels.season_measure(@season)}</th>
                <th :if={@season.scoring == :elo} class="px-2 py-2 text-right font-medium">
                  {gettext("W / L")}
                </th>
                <th class="px-2 py-2 text-right font-medium">{gettext("Matches")}</th>
                <th class="px-4 py-2 text-right font-medium sm:px-5">{gettext("Prize")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr
                :for={{score, index} <- Enum.with_index(@standings, 1)}
                class={["hover:bg-base-200/50", not score.qualified && "text-muted"]}
              >
                <td class="px-4 py-2 sm:px-5">
                  <span class={["leaderboard-medal", "leaderboard-medal-#{min(index, 4)}"]}>{index}</span>
                </td>
                <td class="px-2 py-2">
                  <.link navigate={~p"/players/#{score.player_id}"} class="hover:underline">
                    {score.player_name || score.player_id}
                  </.link>
                  <%= if @season.scoring == :elo do %>
                    <span :if={score.matches < @rating["placement"]} class="ml-1 text-xs text-muted">
                      {gettext("placement")}
                    </span>
                    <RatingComponents.tier_badge
                      :if={score.matches >= @rating["placement"]}
                      tier={Rating.tier(score.score, @rating)}
                    />
                  <% end %>
                </td>
                <td class="px-2 py-2 text-right font-mono tabular-nums">{score.score}</td>
                <td
                  :if={@season.scoring == :elo}
                  class="px-2 py-2 text-right font-mono text-xs tabular-nums"
                >
                  <span class="text-success">{score.wins}</span>
                  / <span class="text-error">{score.losses}</span>
                </td>
                <td class="px-2 py-2 text-right font-mono tabular-nums">{score.matches}</td>
                <td class="px-4 py-2 text-right text-xs sm:px-5">
                  <%= cond do %>
                    <% score.rank && score.rewarded_at -> %>
                      <span class="font-medium text-primary">{gettext("Rewarded")}</span>
                    <% score.rank -> %>
                      <span class="text-warning">{gettext("Won, reward failed")}</span>
                    <% not score.qualified -> %>
                      {gettext("needs more matches")}
                    <% @season.status == :active and in_line?(@qualified, score, @season) -> %>
                      <span class="text-primary">{gettext("In line")}</span>
                    <% true -> %>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </.card>

        <.card
          :if={@season.scoring == :elo}
          title={gettext("How the rating works")}
          icon="hero-calculator"
        >
          <RatingComponents.rating_summary config={@season.rating} />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp in_line?(qualified, score, season) do
    qualified
    |> Enum.take(season.winners_count)
    |> Enum.any?(&(&1.id == score.id))
  end
end
