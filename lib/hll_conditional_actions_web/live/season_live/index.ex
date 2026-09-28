defmodule HllConditionalActionsWeb.SeasonLive.Index do
  @moduledoc """
  Seasons: leaderboards over a stretch of time whose top players are
  rewarded when it ends. The admin picks how long a season lasts, what it
  counts, how many players win and what they get; each match adds to it and
  `HllConditionalActions.Workers.FinalizeSeasons` closes it.

  A season runs on the servers the admin picks - one, or several of the
  same game - and a rating season takes a formula put together in
  `HllConditionalActionsWeb.RatingComponents.rating_builder/1`.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_progression}}

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Preview
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActions.Progression.Season
  alias HllConditionalActions.Servers
  alias HllConditionalActionsWeb.RatingComponents

  @durations [7, 14, 30, 60, 90]

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    all = Servers.list_servers_for(socket.assigns.current_user)
    scope = Enum.find(all, &(to_string(&1.id) == params["server_id"]))

    {:ok,
     socket
     |> assign(:page_title, gettext("Seasons"))
     # Under /servers/:id the seasons are that server's, and a new one is
     # created for it.
     |> assign(:scope, scope)
     |> assign(:servers, if(scope, do: [scope], else: all))
     # A new season can take any server the user reaches, not only the one
     # whose page this is: that is how a season spans servers.
     |> assign(:all_servers, all)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    if Accounts.can?(socket.assigns.current_user, :manage_progression) and
         socket.assigns.servers != [] do
      defaults = %{
        "name" => gettext("Season 1"),
        "server_ids" => [socket.assigns.servers |> List.first() |> Map.get(:id) |> to_string()],
        "scoring" => "elo",
        "rating" => Rating.defaults(),
        "metric" => "teamplay",
        "weights" => %{"combat" => "1", "support" => "2", "offense" => "1", "defense" => "1"},
        "duration_days" => 30,
        "winners_count" => 3,
        "min_matches" => 5,
        "reward_vip_hours" => 168,
        "auto_renew" => true
      }

      servers = socket.assigns.all_servers

      socket
      |> assign(:preview_matches, nil)
      |> assign(:preview, nil)
      # The history is read once, for every server the season could take;
      # picking servers afterwards only filters it.
      |> start_async(:preview_matches, fn -> Preview.recent_matches(servers) end)
      |> validate(defaults)
    else
      push_patch(socket, to: ~p"/seasons")
    end
  end

  defp apply_action(socket, _index), do: assign(socket, :form, nil)

  @impl Phoenix.LiveView
  def handle_event("validate", %{"season" => params}, socket) do
    {:noreply, validate(socket, params)}
  end

  # The duration shortcuts fill the one duration field rather than being
  # inputs of their own, so the form never posts two competing values.
  def handle_event("set_duration", %{"days" => days}, socket) do
    {:noreply, validate(socket, Map.put(socket.assigns.params, "duration_days", days))}
  end

  def handle_event("rating_preset", %{"preset" => preset}, socket) do
    if preset in Rating.presets() do
      {:noreply,
       validate(socket, Map.put(socket.assigns.params, "rating", Rating.preset(preset)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"season" => params}, socket) do
    params = with_rating(params)
    reachable = Enum.map(socket.assigns.all_servers, &to_string(&1.id))
    allowed? = Enum.all?(server_ids(params), &(&1 in reachable))

    case allowed? && Progression.create_season(params) do
      {:ok, season} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Season \"%{name}\" started.", name: season.name))
         |> push_navigate(to: ~p"/seasons/#{season.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      false ->
        {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:preview_matches, {:ok, matches}, socket) do
    {:noreply, socket |> assign(:preview_matches, matches) |> assign_preview()}
  end

  def handle_async(:preview_matches, _failed, socket) do
    {:noreply, socket |> assign(:preview_matches, []) |> assign_preview()}
  end

  defp validate(socket, params) do
    params = with_rating(params)
    changeset = %Season{} |> Progression.change_season(params) |> Map.put(:action, :validate)

    socket
    |> assign(:params, params)
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)
    |> assign_preview()
  end

  # The standings the season as typed would show after the last matches of
  # the servers picked, recomputed on every change.
  defp assign_preview(socket) do
    matches = socket.assigns[:preview_matches]
    season = Ecto.Changeset.apply_changes(socket.assigns.changeset)
    ids = socket.assigns.params |> server_ids() |> MapSet.new()

    preview =
      cond do
        matches == nil ->
          :loading

        season.scoring in [:sum, :average] and season.metric == nil ->
          :needs_stat

        true ->
          matches
          |> Enum.filter(&MapSet.member?(ids, to_string(&1.server_id)))
          |> then(&Preview.season(season, &1, max(season.winners_count || 3, 5)))
      end

    assign(socket, :preview, preview)
  end

  # The rating as it will be stored, named after the preset it still
  # matches - or "custom" once a setting was changed by hand.
  defp with_rating(params) do
    rating = Rating.normalize(params["rating"])

    same = fn preset ->
      Map.delete(Rating.preset(preset), "preset") == Map.delete(rating, "preset")
    end

    Map.put(
      params,
      "rating",
      Map.put(rating, "preset", Enum.find(Rating.presets(), "custom", same))
    )
  end

  defp server_ids(params) do
    params |> Map.get("server_ids", []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp load(socket) do
    seasons = Progression.list_seasons(Enum.map(socket.assigns.servers, & &1.id))

    previews =
      for season <- seasons, season.status == :active, into: %{} do
        {season.id, Progression.standings(season, limit: season.winners_count)}
      end

    socket
    |> assign(:seasons, seasons)
    |> assign(:previews, previews)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={@page_title}
      page_subtitle={gettext("Leaderboards over time, with a reward for the best when they end")}
    >
      <:actions>
        <.button
          :if={Accounts.can?(@current_user, :manage_progression) and @servers != []}
          link_type="live_patch"
          to={~p"/seasons/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New season")}
        />
      </:actions>

      <.empty_state
        :if={@seasons == []}
        icon="hero-calendar-days"
        title={gettext("No season yet")}
        description={
          gettext(
            "A season adds up one stat over every match for a few weeks - teamplay, kills, support... - and gives VIP to the top players when it ends. It can start the next one on its own."
          )
        }
      />

      <ul :if={@seasons != []} id="seasons" class="grid gap-4 lg:grid-cols-2">
        <li :for={season <- @seasons} id={"season-#{season.id}"}>
          <.link
            navigate={~p"/seasons/#{season.id}"}
            class="block h-full rounded-box bg-base-100 p-4 shadow-figma-card transition-shadow hover:shadow-figma-card-medium sm:p-5"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="text-xs font-medium tracking-wide text-muted uppercase">
                  {servers_label(season)} · {Labels.season_measure(season)}
                </p>
                <p class="mt-0.5 truncate text-lg font-semibold">{season.name}</p>
              </div>
              <.tone_badge tone={if season.status == :active, do: "success", else: "ghost"}>
                {if season.status == :active, do: gettext("Running"), else: gettext("Finished")}
              </.tone_badge>
            </div>

            <div :if={season.status == :active} class="mt-3">
              <div class="flex justify-between text-xs text-muted">
                <span>{Calendar.strftime(season.starts_at, "%d/%m")}</span>
                <span>{days_left(season, @now)}</span>
                <span>{Calendar.strftime(season.ends_at, "%d/%m")}</span>
              </div>
              <div class="mt-1 h-1.5 overflow-hidden rounded-pill bg-base-200">
                <div class="h-full rounded-pill bg-primary" style={"width: #{elapsed(season, @now)}%"}>
                </div>
              </div>
            </div>

            <ol :if={season.status == :active} class="mt-3 space-y-1">
              <li
                :for={{score, rank} <- Enum.with_index(Map.get(@previews, season.id, []), 1)}
                class="flex items-center gap-2 text-sm"
              >
                <span class={["leaderboard-medal", "leaderboard-medal-#{min(rank, 4)}"]}>{rank}</span>
                <span class="min-w-0 flex-1 truncate">{score.player_name}</span>
                <span class="font-mono text-xs tabular-nums">{score.score}</span>
              </li>
              <li :if={Map.get(@previews, season.id, []) == []} class="text-xs text-muted">
                {gettext("Nobody has scored yet: the first match to end starts it.")}
              </li>
            </ol>

            <p class="mt-3 flex flex-wrap gap-1.5 text-[0.6875rem]">
              <span class="rounded-pill bg-primary/10 px-2 py-0.5 font-medium text-primary">
                {ngettext("Top 1 wins", "Top %{count} win", season.winners_count)}
              </span>
              <span :if={season.reward_vip_hours > 0} class="rounded-pill bg-base-200 px-2 py-0.5">
                VIP {vip_label(season.reward_vip_hours)}
              </span>
              <span class="rounded-pill bg-base-200 px-2 py-0.5">
                {ngettext("1 day", "%{count} days", season.duration_days)}
              </span>
              <span :if={season.auto_renew} class="rounded-pill bg-base-200 px-2 py-0.5">
                {gettext("Renews")}
              </span>
            </p>
          </.link>
        </li>
      </ul>

      <.modal
        :if={@form}
        id="season-modal"
        title={gettext("New season")}
        subtitle={gettext("It starts now. Every match that ends on the server adds to it.")}
        on_cancel={JS.patch(~p"/seasons")}
        class="max-w-5xl"
      >
        <.form for={@form} id="season-form" phx-change="validate" phx-submit="save">
          <%!-- The settings on the left, what they would do on the right: the
                preview stays in view while anything changes. --%>
          <div class="form-with-preview">
            <div class="min-w-0">
              <%!-- 1. What it is ─────────────────────────────────────────── --%>
              <.form_section title={gettext("Season")}>
                <.input field={@form[:name]} type="text" label={gettext("Name")} required />
                <div id="season-servers">
                  <span class="rating-label">{gettext("Where it counts")}</span>
                  <input type="hidden" name="season[server_ids][]" value="" />
                  <div :for={{game, servers} <- by_game(@all_servers)} class="mt-1.5">
                    <p :if={length(by_game(@all_servers)) > 1} class="mb-1 text-xs text-muted">
                      {Labels.game(game)}
                    </p>
                    <div class="flex flex-wrap gap-2">
                      <label :for={server <- servers} class="server-chip">
                        <input
                          type="checkbox"
                          name="season[server_ids][]"
                          value={server.id}
                          checked={to_string(server.id) in server_ids(@params)}
                          class="sr-only"
                        />
                        <.icon name="hero-server" class="size-4 text-muted" />
                        {server.name}
                      </label>
                    </div>
                  </div>
                  <p class="rating-hint">
                    {gettext(
                      "One server, or several of the same game: a season across servers ranks everybody together and rewards the winners on all of them."
                    )}
                  </p>
                  <p :for={{message, _opts} <- @form[:servers].errors} class="mt-1 text-sm text-error">
                    {translate_error({message, []})}
                  </p>
                </div>
              </.form_section>

              <%!-- 2. How it ranks ───────────────────────────────────────── --%>
              <.form_section title={gettext("How players are ranked")}>
                <div class="grid gap-2 sm:grid-cols-2" role="radiogroup">
                  <label :for={method <- Scoring.methods()} class="scoring-option">
                    <input
                      type="radio"
                      name={@form[:scoring].name}
                      value={method}
                      checked={to_string(@form[:scoring].value) == to_string(method)}
                      class="peer sr-only"
                    />
                    <span class="scoring-card">
                      <span class="flex items-center gap-2 text-sm font-medium">
                        <.icon name={scoring_icon(method)} class="size-4 text-primary" />
                        {Labels.scoring(method)}
                      </span>
                      <span class="mt-1 block text-xs text-muted">{Labels.scoring_hint(method)}</span>
                    </span>
                  </label>
                </div>

                <div :if={scoring(@form) in [:sum, :average]} class="mt-3 max-w-sm">
                  <.input
                    field={@form[:metric]}
                    type="select"
                    label={gettext("Stat")}
                    options={Labels.metric_options(Metrics.match())}
                  />
                </div>

                <div :if={scoring(@form) == :weighted} class="mt-3">
                  <p class="mb-2 text-xs text-muted">
                    {gettext("Points per unit of each stat. Zero leaves it out.")}
                  </p>
                  <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
                    <label :for={metric <- Scoring.weighted_metrics()} class="weight-field">
                      <span class="truncate text-xs text-subtle">{Labels.metric(metric)}</span>
                      <input
                        type="number"
                        min="0"
                        max="10"
                        name={"#{@form[:weights].name}[#{metric}]"}
                        value={Scoring.weight(@form[:weights].value, metric)}
                        class="pc-text-input w-16 text-center"
                      />
                    </label>
                  </div>
                  <p :for={{message, _opts} <- @form[:weights].errors} class="mt-1 text-sm text-error">
                    {message}
                  </p>
                </div>
              </.form_section>

              <.form_section :if={scoring(@form) == :elo} title={gettext("Rating formula")}>
                <RatingComponents.rating_builder name="season[rating]" config={@params["rating"]} />
                <p class="text-xs text-muted">
                  <.icon name="hero-information-circle" class="mr-1 inline size-4 align-text-bottom" />
                  {gettext(
                    "A match whose result is unknown changes no rating, so a rating season needs CRCON reachable when matches end."
                  )}
                </p>
              </.form_section>

              <%!-- 3. How long ───────────────────────────────────────────── --%>
              <.form_section title={gettext("How long it lasts")}>
                <div
                  class="flex flex-wrap items-center gap-2"
                  role="group"
                  aria-label={gettext("How long it lasts")}
                >
                  <button
                    :for={days <- durations()}
                    type="button"
                    phx-click="set_duration"
                    phx-value-days={days}
                    class={[
                      "duration-chip",
                      to_string(@form[:duration_days].value) == to_string(days) && "is-active"
                    ]}
                  >
                    {ngettext("1 day", "%{count} days", days)}
                  </button>
                  <%!-- The custom length reads as one more chip: the same height and
                    radius, a number and its unit inside, so the row never
                    breaks between "or", the box and "days". --%>
                  <label class={[
                    "duration-custom",
                    to_string(@form[:duration_days].value) not in Enum.map(durations(), &to_string/1) &&
                      "is-active"
                  ]}>
                    <span class="text-muted">{gettext("Other")}</span>
                    <input
                      type="number"
                      min="1"
                      max="365"
                      name={@form[:duration_days].name}
                      value={@form[:duration_days].value}
                      aria-label={gettext("Days")}
                    />
                    <span class="text-muted">{gettext("days")}</span>
                  </label>
                </div>
                <p
                  :for={{message, _opts} <- @form[:duration_days].errors}
                  class="mt-1 text-sm text-error"
                >
                  {message}
                </p>
              </.form_section>

              <%!-- 4. What the best get ──────────────────────────────────── --%>
              <.form_section title={gettext("Reward")}>
                <div class="grid gap-3 sm:grid-cols-3">
                  <.input
                    field={@form[:winners_count]}
                    type="number"
                    min="1"
                    max="50"
                    label={gettext("Winners")}
                  />
                  <.input
                    field={@form[:min_matches]}
                    type="number"
                    min="0"
                    label={gettext("Min. matches")}
                  />
                  <.input
                    field={@form[:reward_vip_hours]}
                    type="number"
                    min="0"
                    label={gettext("VIP (hours)")}
                  />
                </div>
                <.input
                  field={@form[:auto_renew]}
                  type="checkbox"
                  label={gettext("Start the next season as soon as this one ends")}
                />
              </.form_section>

              <p id="season-summary" class="season-summary">
                <.icon name="hero-trophy" class="size-5 shrink-0 text-primary" />
                <span>{summary(@form)}</span>
              </p>

              <div class="flex justify-end gap-2 pt-4">
                <.button
                  link_type="live_patch"
                  to={~p"/seasons"}
                  variant="outline"
                  color="gray"
                  label={gettext("Cancel")}
                />
                <.button
                  type="submit"
                  color="primary"
                  icon="hero-play"
                  phx-disable-with={gettext("Saving...")}
                  label={gettext("Start the season")}
                />
              </div>
            </div>
            <aside class="form-preview-aside">
              <.season_preview
                preview={@preview}
                winners={@form[:winners_count].value}
                measure={Labels.season_measure(Ecto.Changeset.apply_changes(@changeset))}
              />
              <RatingComponents.rating_preview
                :if={scoring(@form) == :elo}
                config={@params["rating"]}
              />
            </aside>
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end

  defp durations, do: @durations

  attr :preview, :any, required: true
  attr :winners, :any, required: true
  attr :measure, :string, required: true

  defp season_preview(assigns) do
    assigns = assign(assigns, :winners, to_int(assigns.winners, 3))

    ~H"""
    <div id="season-preview" class="preview-panel">
      <p class="preview-eyebrow">
        <span class="live-dot"></span>{gettext("Live preview")}
      </p>

      <%= case @preview do %>
        <% :loading -> %>
          <p class="mt-2 text-xs text-muted">{gettext("Reading the last matches from CRCON...")}</p>
          <div class="mt-3 space-y-2">
            <div :for={_ <- 1..5} class="h-6 animate-pulse rounded-field bg-base-200"></div>
          </div>
        <% :needs_stat -> %>
          <p class="mt-2 text-sm text-muted">{gettext("Pick the stat to see the standings.")}</p>
        <% %{matches: 0} -> %>
          <p class="mt-2 text-sm text-muted">
            {gettext(
              "No finished match in CRCON's history for these servers yet: the preview shows up after the first ones."
            )}
          </p>
        <% preview -> %>
          <p class="mt-1 text-xs text-muted">
            {ngettext(
              "If it had counted the last match:",
              "If it had counted the last %{count} matches:",
              preview.matches
            )}
          </p>
          <ol class="mt-3 space-y-1.5">
            <li
              :for={{row, rank} <- Enum.with_index(preview.top, 1)}
              class={["preview-rank", rank <= @winners && "is-winner"]}
            >
              <span class={["leaderboard-medal", "leaderboard-medal-#{min(rank, 4)}"]}>{rank}</span>
              <span class="min-w-0 flex-1 truncate">{row.name || row.player_id}</span>
              <.icon :if={rank <= @winners} name="hero-gift" class="size-3.5 text-primary" />
              <span class="font-mono text-xs tabular-nums">{row.score}</span>
            </li>
            <li :if={preview.top == []} class="text-xs text-muted">
              {gettext("Nobody played the minimum matches in this stretch.")}
            </li>
          </ol>
          <p class="mt-3 border-t border-base-300 pt-2 text-[0.6875rem] text-muted">
            {@measure} · {ngettext("1 player scored", "%{count} players scored", preview.players)} · {ngettext(
              "1 with the minimum matches",
              "%{count} with the minimum matches",
              preview.qualified
            )}
          </p>
      <% end %>
    </div>
    """
  end

  defp by_game(servers) do
    servers |> Enum.group_by(& &1.game) |> Enum.sort_by(fn {game, _servers} -> game end)
  end

  @doc false
  def servers_label(%{servers: [server]}), do: server.name

  def servers_label(%{servers: servers}),
    do: ngettext("1 server", "%{count} servers", length(servers))

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp form_section(assigns) do
    ~H"""
    <%!-- A div and a heading, not a fieldset and legend: browsers draw the
          legend on top of the fieldset's border, which glued every title to
          the line above it. --%>
    <section class="form-section">
      <h3 class="form-section-title">{@title}</h3>
      <div class="space-y-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  defp scoring(form) do
    case to_string(form[:scoring].value) do
      "average" -> :average
      "weighted" -> :weighted
      "elo" -> :elo
      _sum -> :sum
    end
  end

  defp scoring_icon(:sum), do: "hero-plus-circle"
  defp scoring_icon(:average), do: "hero-scale"
  defp scoring_icon(:weighted), do: "hero-adjustments-horizontal"
  defp scoring_icon(:elo), do: "hero-chart-bar-square"

  # The whole season in one sentence, so what it will do is never a guess.
  defp summary(form) do
    winners = to_int(form[:winners_count].value, 3)

    gettext(
      "The top %{winners} by %{ranking} after %{days} days, with at least %{matches} matches played, get %{vip} hours of VIP.",
      winners: winners,
      ranking: ranking_phrase(form),
      days: to_int(form[:duration_days].value, 30),
      matches: to_int(form[:min_matches].value, 0),
      vip: to_int(form[:reward_vip_hours].value, 0)
    )
  end

  defp ranking_phrase(form) do
    case scoring(form) do
      :elo -> gettext("Elo rating")
      :weighted -> gettext("combined score")
      scoring -> "#{String.downcase(Labels.scoring(scoring))} (#{metric_label(form)})"
    end
  end

  defp metric_label(form) do
    case form[:metric].value do
      nil -> "-"
      "" -> "-"
      metric when is_atom(metric) -> Labels.metric(metric)
      metric -> metric |> String.to_existing_atom() |> Labels.metric()
    end
  rescue
    ArgumentError -> "-"
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  @doc false
  def days_left(season, now) do
    case DateTime.diff(season.ends_at, now, :hour) do
      hours when hours <= 0 -> gettext("ending")
      hours when hours < 48 -> ngettext("1 hour left", "%{count} hours left", hours)
      hours -> ngettext("1 day left", "%{count} days left", div(hours, 24))
    end
  end

  @doc false
  def elapsed(season, now) do
    total = max(DateTime.diff(season.ends_at, season.starts_at), 1)
    (DateTime.diff(now, season.starts_at) * 100 / total) |> max(0) |> min(100) |> round()
  end

  @doc false
  def vip_label(hours) when rem(hours, 24) == 0,
    do: ngettext("1 day", "%{count} days", div(hours, 24))

  def vip_label(hours), do: "#{hours}h"
end
