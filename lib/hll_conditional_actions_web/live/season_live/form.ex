defmodule HllConditionalActionsWeb.SeasonLive.Form do
  @moduledoc """
  The season form (SeasonForm board), shared by the new season page
  (`SeasonLive.Index`, `:new`) and the edit mode of a season
  (`SeasonLive.Show`, `/seasons/:id/edit`): name, length and start, servers, how the
  score is made - a formula of stats and weights for a combined season -
  and the prize, with the standings the season would show after the
  servers' last matches beside it, compared with the running season.

  The LiveViews hand their form events and the preview's async result to
  `handle_event/3` and `handle_async/3`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.CommunityComponents
  import Phoenix.LiveView, only: [start_async: 3, push_navigate: 2, put_flash: 3]

  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Metrics
  alias HllConditionalActions.Progression.Preview
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActions.Progression.Season
  alias HllConditionalActionsWeb.RatingComponents
  alias HllConditionalActionsWeb.SeasonLive.Dashboard

  @events ~w(validate save step add_metric remove_metric rating_preset)
  @durations [7, 14, 30, 60]
  @default_formula [{"combat", 1}, {"support", 0.6}, {"defense", 0.4}, {"offense", 0.3}]

  @doc "The events the form handles."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  Opens the form: for a new season on `server_ids` when `season` is nil,
  or to change `season`. `servers` are the servers the user reaches.
  """
  @spec open(Phoenix.LiveView.Socket.t(), Season.t() | nil, [map()], [term()]) ::
          Phoenix.LiveView.Socket.t()
  def open(socket, season, servers, server_ids) do
    params =
      if season do
        season_params(season)
      else
        first = Enum.find(servers, &(&1.id in server_ids))

        server_ids
        |> new_params()
        |> Map.put("starts_at", local_input(DateTime.utc_now(), first))
      end

    socket
    |> assign(:editing, season)
    |> assign(:form_servers, servers)
    |> assign(:preview_loaded, %{})
    |> assign(:preview_pending, MapSet.new())
    |> assign(:current, nil)
    |> validate(params)
  end

  defp new_params(server_ids) do
    %{
      "name" => "",
      "server_ids" => Enum.map(server_ids, &to_string/1),
      "scoring" => "weighted",
      "rating" => Rating.defaults(),
      "metric" => "teamplay",
      "formula" => formula_params(@default_formula),
      "per_match" => "true",
      "duration_days" => "30",
      "starts_at" => "",
      "winners_count" => "3",
      "min_matches" => "5",
      "reward_vip_hours" => "720",
      "auto_renew" => "true"
    }
  end

  defp season_params(season) do
    rows =
      Scoring.weighted_metrics()
      |> Enum.map(&{to_string(&1), Scoring.weight(season.weights, &1)})
      |> Enum.reject(fn {_metric, weight} -> weight == 0 end)
      |> Enum.sort_by(fn {_metric, weight} -> -weight end)

    %{
      "name" => season.name,
      "server_ids" => Enum.map(season.servers, &to_string(&1.id)),
      "scoring" => to_string(season.scoring),
      "rating" => Rating.normalize(season.rating),
      "metric" => to_string(season.metric || "teamplay"),
      "formula" => formula_params(if(rows == [], do: @default_formula, else: rows)),
      "per_match" => to_string(season.per_match),
      "duration_days" => to_string(season.duration_days),
      "starts_at" => local_input(season.starts_at, List.first(season.servers)),
      "winners_count" => to_string(season.winners_count),
      "min_matches" => to_string(season.min_matches),
      "reward_vip_hours" => to_string(season.reward_vip_hours),
      "auto_renew" => to_string(season.auto_renew)
    }
  end

  defp formula_params(rows) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {{metric, weight}, index} ->
      {to_string(index), %{"metric" => metric, "weight" => Dashboard.weight_text(weight)}}
    end)
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @doc "Handles one of `events/0`."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate", %{"season" => params}, socket) do
    {:noreply, validate(socket, Map.merge(socket.assigns.params, params))}
  end

  def handle_event("step", %{"field" => field, "by" => by}, socket)
      when field in ~w(winners_count min_matches) do
    params = socket.assigns.params
    value = to_int(params[field], 0) + to_int(by, 0)
    value = if field == "winners_count", do: value |> max(1) |> min(50), else: max(value, 0)
    {:noreply, validate(socket, Map.put(params, field, to_string(value)))}
  end

  def handle_event("add_metric", _params, socket) do
    params = socket.assigns.params
    rows = rows(params)
    used = Enum.map(rows, & &1["metric"])

    case Enum.find(Scoring.weighted_metrics(), &(to_string(&1) not in used)) do
      nil ->
        {:noreply, socket}

      metric ->
        rows = rows ++ [%{"metric" => to_string(metric), "weight" => Dashboard.weight_text(1)}]
        {:noreply, validate(socket, Map.put(params, "formula", rows_params(rows)))}
    end
  end

  def handle_event("remove_metric", %{"index" => index}, socket) do
    params = socket.assigns.params
    rows = List.delete_at(rows(params), to_int(index, -1))
    {:noreply, validate(socket, Map.put(params, "formula", rows_params(rows)))}
  end

  def handle_event("rating_preset", %{"preset" => preset}, socket) do
    if preset in Rating.presets(),
      do:
        {:noreply,
         validate(socket, Map.put(socket.assigns.params, "rating", Rating.preset(preset)))},
      else: {:noreply, socket}
  end

  def handle_event("save", %{"season" => params}, socket) do
    params = socket.assigns.params |> Map.merge(params) |> prepare(socket.assigns.form_servers)
    reachable = Enum.map(socket.assigns.form_servers, &to_string(&1.id))
    allowed? = Enum.all?(server_ids(params), &(&1 in reachable))

    result =
      cond do
        not allowed? -> :forbidden
        socket.assigns.editing -> Progression.update_season(socket.assigns.editing, params)
        true -> Progression.create_season(params)
      end

    case result do
      {:ok, season} ->
        message =
          if socket.assigns.editing,
            do: gettext("Season \"%{name}\" saved.", name: season.name),
            else: gettext("Season \"%{name}\" started.", name: season.name)

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/seasons/#{season.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), changeset: changeset)}

      :forbidden ->
        {:noreply, put_flash(socket, :error, gettext("You do not have access to that page."))}
    end
  end

  @doc """
  The match history of one server arrived (`{:preview, server_id}`). Each
  server is read on its own, when it is first picked, so a slow CRCON only
  holds back the seasons that include it.
  """
  @spec handle_async(term(), term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async({:preview, id}, result, socket) do
    matches =
      case result do
        {:ok, matches} -> matches
        _failed -> []
      end

    {:noreply,
     socket
     |> update(:preview_loaded, &Map.put(&1, id, matches))
     |> update(:preview_pending, &MapSet.delete(&1, id))
     |> assign_preview()}
  end

  # Reads the history of the servers picked that were not read yet.
  defp load_history(socket) do
    ids = socket.assigns.params |> server_ids() |> Enum.map(&to_int(&1, 0))
    %{preview_loaded: loaded, preview_pending: pending} = socket.assigns

    socket.assigns.form_servers
    |> Enum.filter(&(&1.id in ids and not Map.has_key?(loaded, &1.id) and &1.id not in pending))
    |> Enum.reduce(socket, fn server, socket ->
      socket
      |> update(:preview_pending, &MapSet.put(&1, server.id))
      |> start_async({:preview, server.id}, fn -> Preview.recent_matches([server]) end)
    end)
  end

  # ── State ──────────────────────────────────────────────────────────────────

  defp validate(socket, params) do
    prepared = prepare(params, socket.assigns.form_servers)
    base = socket.assigns.editing || %Season{}

    changeset =
      base
      |> Progression.change_season(prepared)
      |> Map.put(:action, if(params["name"] in [nil, ""], do: nil, else: :validate))

    socket
    |> assign(:params, params)
    |> assign(:form, to_form(changeset))
    |> assign(:changeset, changeset)
    |> assign_current()
    |> load_history()
    |> assign_preview()
  end

  # What the changeset takes: the formula rows become weights, the start
  # typed in the first server's time becomes UTC, the rating takes the
  # preset it still matches.
  defp prepare(params, servers) do
    weights =
      params
      |> rows()
      |> Map.new(&{&1["metric"], &1["weight"]})

    first = Enum.find(servers, &(to_string(&1.id) in server_ids(params)))

    params
    |> Map.put("weights", weights)
    |> Map.put("starts_at", utc_start(params["starts_at"], first))
    |> with_rating()
  end

  defp rows(params) do
    case params["formula"] do
      %{} = rows ->
        rows
        |> Enum.sort_by(fn {index, _row} -> to_int(index, 0) end)
        |> Enum.map(fn {_index, row} -> row end)

      rows when is_list(rows) ->
        rows

      _none ->
        []
    end
  end

  defp rows_params(rows) do
    rows |> Enum.with_index() |> Map.new(fn {row, index} -> {to_string(index), row} end)
  end

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

  defp utc_start(value, server) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value
    zone = (server && server.timezone) || "Etc/UTC"

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, at} <- DateTime.from_naive(naive, zone) do
      at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
    else
      _invalid -> nil
    end
  end

  defp utc_start(_value, _server), do: nil

  defp local_input(nil, _server), do: ""

  defp local_input(at, server),
    do: at |> local(server) |> Calendar.strftime("%Y-%m-%dT%H:%M")

  defp server_ids(params) do
    params |> Map.get("server_ids", []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
  end

  # The running season of the servers picked, the one the preview compares
  # with ("vs atual").
  defp assign_current(socket) do
    ids = socket.assigns.params |> server_ids() |> Enum.map(&to_int(&1, 0))

    current =
      ids
      |> then(&if(&1 == [], do: [], else: Progression.list_seasons(&1)))
      |> Enum.find(&(&1.status == :active))

    if current && socket.assigns.current && socket.assigns.current.season.id == current.id do
      socket
    else
      assign(
        socket,
        :current,
        current &&
          %{
            season: current,
            ranks:
              current
              |> Progression.standings(limit: 500)
              |> Enum.filter(& &1.qualified)
              |> Enum.with_index(1)
              |> Map.new(fn {score, rank} -> {score.player_id, rank} end),
            leader: current |> Progression.standings(limit: 1) |> List.first()
          }
      )
    end
  end

  defp assign_preview(socket) do
    season = Ecto.Changeset.apply_changes(socket.assigns.changeset)
    ids = socket.assigns.params |> server_ids() |> Enum.map(&to_int(&1, 0))
    %{preview_loaded: loaded, preview_pending: pending} = socket.assigns

    preview =
      cond do
        Enum.any?(ids, &MapSet.member?(pending, &1)) ->
          :loading

        season.scoring in [:sum, :average] and season.metric == nil ->
          :needs_stat

        true ->
          ids
          |> Enum.flat_map(&Map.get(loaded, &1, []))
          |> Enum.sort_by(& &1.ended_at, DateTime)
          |> then(&Preview.season(season, &1, 8))
      end

    assign(socket, :preview, preview)
  end

  # ── Rendering ──────────────────────────────────────────────────────────────

  @doc "The form and its preview. The page puts the header around it."
  attr :form, :any, required: true
  attr :params, :map, required: true
  attr :preview, :any, required: true
  attr :current, :any, required: true
  attr :servers, :list, required: true
  attr :editing, :any, default: nil

  def form_page(assigns) do
    assigns =
      assign(assigns,
        scoring: scoring(assigns.form),
        rows: rows(assigns.params),
        draft: Ecto.Changeset.apply_changes(assigns.form.source),
        parts: parts(assigns.preview)
      )

    ~H"""
    <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_26.875rem] xl:items-stretch">
      <.form
        for={@form}
        id="season-form"
        phx-change="validate"
        phx-submit="save"
        class="flex min-w-0 flex-col gap-4 rounded-[1.75rem] bg-base-100 px-4 py-5 shadow-[var(--shadow-card)] sm:px-7 sm:py-[1.375rem]"
      >
        <div class="grid gap-3.5 lg:grid-cols-[minmax(0,1fr)_17.25rem_10.625rem] lg:items-end">
          <label class="flex flex-col gap-2">
            <span class="com-label">{gettext("Name")}</span>
            <input
              type="text"
              name={@form[:name].name}
              value={@form[:name].value}
              placeholder={gettext("Winter season")}
              class="com-field"
              required
            />
          </label>
          <div class="flex flex-col gap-2">
            <span class="com-label">{gettext("Length")}</span>
            <.radio_seg
              id="season-duration"
              name={@form[:duration_days].name}
              value={@form[:duration_days].value}
              label={gettext("Length")}
              options={duration_options(@form[:duration_days].value)}
            />
          </div>
          <label class="flex flex-col gap-2">
            <span class="com-label">{gettext("Starts at")}</span>
            <input
              type="datetime-local"
              name="season[starts_at]"
              value={@params["starts_at"]}
              aria-label={gettext("Starts at")}
              class="com-field text-sm"
            />
          </label>
        </div>
        <p
          :for={msg <- errors(@form, :name) ++ errors(@form, :duration_days)}
          class="-mt-2 text-sm text-error"
        >
          {msg}
        </p>

        <div class="grid gap-3.5 lg:grid-cols-[minmax(0,1fr)_18.75rem] lg:items-end">
          <div class="flex flex-col gap-2" id="season-servers">
            <span class="com-label">{gettext("Servers")}</span>
            <input type="hidden" name="season[server_ids][]" value="" />
            <div class="flex flex-wrap gap-2" role="group" aria-label={gettext("Servers")}>
              <label :for={server <- @servers} class="com-chip">
                <input
                  type="checkbox"
                  name="season[server_ids][]"
                  value={server.id}
                  checked={to_string(server.id) in server_ids(@params)}
                  class="sr-only"
                />
                <span>
                  <.icon name="hero-check" class="com-chip-check size-4" />
                  {server.name}
                </span>
              </label>
            </div>
            <p :for={msg <- errors(@form, :servers)} class="text-sm text-error">{msg}</p>
          </div>
          <div class="flex h-12 items-center gap-3 rounded-[0.875rem] border border-line-raised bg-secondary pr-3 pl-4">
            <span class="flex min-w-0 flex-1 flex-col">
              <strong class="text-sm font-semibold">{gettext("Renew on its own")}</strong>
              <span class="truncate text-[0.6875rem] text-muted">
                {gettext("opens the next one when this one closes")}
              </span>
            </span>
            <.toggle_switch
              id="season-auto-renew"
              name={@form[:auto_renew].name}
              checked={truthy?(@form[:auto_renew].value)}
              label={gettext("Renew on its own")}
            />
          </div>
        </div>

        <.section_label>{gettext("How the score is made")}</.section_label>

        <div class="flex flex-wrap items-center gap-3.5">
          <.radio_seg
            id="season-scoring"
            name={@form[:scoring].name}
            value={@form[:scoring].value}
            label={gettext("Scoring")}
            round
            class="w-full sm:w-[28.5rem]"
            options={[
              {gettext("Sum"), "sum"},
              {gettext("Average"), "average"},
              {gettext("Weighted"), "weighted"},
              {gettext("Elo"), "elo"}
            ]}
          />
          <span class="min-w-0 flex-1 text-[0.8125rem] leading-snug text-muted">
            {scoring_hint(@scoring)}
          </span>
        </div>

        <section
          :if={@scoring == :weighted}
          id="season-formula-editor"
          aria-label={gettext("Score formula")}
          class="flex flex-col gap-1.5 rounded-[1.25rem] border border-line-raised bg-secondary px-3 py-3.5 sm:px-4"
        >
          <div class="formula-row pb-1 text-xs text-muted">
            <span class="hidden md:block"></span>
            <span>{gettext("Stat")}</span>
            <span></span>
            <span>{gettext("Weight")}</span>
            <span class="hidden md:block">{gettext("Share of the score")}</span>
            <span></span>
          </div>
          <div :for={{row, index} <- Enum.with_index(@rows)} class="formula-row">
            <span class={[
              "hidden size-7 items-center justify-center rounded-full font-mono text-sm md:flex",
              index > 0 && "bg-base-300 text-subtle"
            ]}>
              {if index > 0, do: "+"}
            </span>
            <select
              name={"season[formula][#{index}][metric]"}
              aria-label={gettext("Stat")}
              class="com-field com-field--sm"
            >
              <option
                :for={metric <- Scoring.weighted_metrics()}
                value={metric}
                selected={to_string(metric) == row["metric"]}
              >
                {String.capitalize(Dashboard.metric_word(metric))}
              </option>
            </select>
            <span class="text-center font-mono text-muted">×</span>
            <input
              type="text"
              inputmode="decimal"
              name={"season[formula][#{index}][weight]"}
              value={row["weight"]}
              aria-label={
                gettext("Weight of %{stat}", stat: Dashboard.metric_word(metric_atom(row["metric"])))
              }
              class="com-field com-field--sm font-mono"
            />
            <span class="hidden items-center gap-2 md:flex">
              <span class="flex h-2 flex-1 rounded bg-base-100">
                <span
                  class={["rounded", "part-#{rem(index, 6)}"]}
                  style={"width: #{share_of(@parts, row["metric"])}%"}
                ></span>
              </span>
              <span class="w-[2.125rem] text-right font-mono text-xs text-subtle">
                {share_of(@parts, row["metric"])}%
              </span>
            </span>
            <button
              type="button"
              phx-click="remove_metric"
              phx-value-index={index}
              aria-label={
                gettext("Remove %{stat}", stat: Dashboard.metric_word(metric_atom(row["metric"])))
              }
              class="size-8 rounded-full text-lg text-muted transition-colors hover:bg-base-300 hover:text-base-content"
            >
              ×
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-2.5 pt-0.5 pb-1 md:pl-10">
            <button
              :if={length(@rows) < length(Scoring.weighted_metrics())}
              id="season-add-metric"
              type="button"
              phx-click="add_metric"
              class="h-[2.125rem] rounded-full border border-dashed border-line-strong px-3.5 text-[0.8125rem] transition-colors hover:bg-base-300"
            >
              + {gettext("Stat")}
            </button>
            <span class="text-xs text-muted">
              {gettext("kills, combat, offense, defense, support, vehicles destroyed")}
            </span>
          </div>
          <p :for={msg <- errors(@form, :weights)} class="text-sm text-error">{msg}</p>
          <div class="grid grid-cols-[1.875rem_minmax(0,1fr)_auto] items-center gap-2.5 border-t border-dashed border-line-strong pt-2.5">
            <span class="flex size-7 items-center justify-center rounded-full bg-primary/14 font-mono text-[0.9375rem] font-semibold text-primary">
              ÷
            </span>
            <span class="text-sm">
              {gettext("matches played")}
              <span class="text-xs text-muted">· {gettext("score per match")}</span>
            </span>
            <.toggle_switch
              id="season-per-match"
              name={@form[:per_match].name}
              checked={truthy?(@form[:per_match].value)}
              label={gettext("Divide by the matches played")}
              small
            />
          </div>
          <div class="mt-1 rounded-xl bg-base-100 px-3 py-2.5 font-mono text-[0.78125rem] text-subtle">
            {formula_text(@draft)}
          </div>
        </section>

        <div :if={@scoring in [:sum, :average]} class="max-w-sm">
          <label class="flex flex-col gap-2">
            <span class="com-label">{gettext("Stat")}</span>
            <select name={@form[:metric].name} class="com-field">
              <option
                :for={{label, value} <- Labels.metric_options(Metrics.match())}
                value={value}
                selected={to_string(@form[:metric].value) == value}
              >
                {label}
              </option>
            </select>
          </label>
        </div>

        <div :if={@scoring == :elo} class="flex flex-col gap-3">
          <RatingComponents.rating_builder name="season[rating]" config={@params["rating"]} />
          <p class="text-xs text-muted">
            {gettext(
              "A match whose result is unknown changes no rating, so a rating season needs CRCON reachable when matches end."
            )}
          </p>
        </div>

        <p
          :if={@editing && @editing.status == :active}
          class="rounded-xl bg-warning/10 px-3.5 py-2.5 text-[0.8125rem] text-warning"
        >
          {gettext(
            "A new way of scoring counts from the next match on: the points already made stay as they are."
          )}
        </p>

        <.section_label>{gettext("Prize")}</.section_label>

        <div class="grid gap-3.5 sm:grid-cols-3">
          <div class="flex flex-col gap-2">
            <span class="com-label">{gettext("Winners")}</span>
            <.count_stepper
              id="season-winners"
              name={@form[:winners_count].name}
              value={@form[:winners_count].value}
              field="winners_count"
              min={1}
              max={50}
              less={gettext("Fewer winners")}
              more={gettext("More winners")}
            />
          </div>
          <div class="flex flex-col gap-2">
            <span class="com-label">{gettext("Minimum matches")}</span>
            <.count_stepper
              id="season-min-matches"
              name={@form[:min_matches].name}
              value={@form[:min_matches].value}
              field="min_matches"
              less={gettext("Fewer matches")}
              more={gettext("More matches")}
            />
          </div>
          <label class="flex flex-col gap-2">
            <span class="com-label">{gettext("VIP hours")}</span>
            <span class="com-field flex items-center gap-2 !px-3.5">
              <input
                type="number"
                min="0"
                name={@form[:reward_vip_hours].name}
                value={@form[:reward_vip_hours].value}
                class="w-full min-w-0 border-0 bg-transparent p-0 font-mono text-base outline-0 focus:ring-0"
              />
              <span class="text-xs whitespace-nowrap text-muted">
                {vip_hint(@form[:reward_vip_hours].value)}
              </span>
            </span>
          </label>
        </div>
        <p
          :for={
            msg <-
              errors(@form, :winners_count) ++
                errors(@form, :min_matches) ++ errors(@form, :reward_vip_hours)
          }
          class="text-sm text-error"
        >
          {msg}
        </p>
      </.form>

      <.preview_panel
        preview={@preview}
        draft={@draft}
        parts={@parts}
        current={@current}
        servers={Enum.filter(@servers, &(to_string(&1.id) in server_ids(@params)))}
      />
    </div>
    """
  end

  attr :preview, :any, required: true
  attr :draft, :map, required: true
  attr :parts, :list, required: true
  attr :current, :any, required: true
  attr :servers, :list, required: true

  defp preview_panel(assigns) do
    assigns =
      assign(assigns,
        winners: max(assigns.draft.winners_count || 3, 1),
        change: podium_change(assigns.current, assigns.preview)
      )

    ~H"""
    <aside
      id="season-preview"
      aria-label={gettext("Standings preview")}
      class="flex min-w-0 flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5 shadow-[var(--shadow-card)]"
    >
      <div class="flex items-center gap-2">
        <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Standings preview")}</h2>
        <.live_mark />
      </div>

      <%= case @preview do %>
        <% :loading -> %>
          <span class="text-[0.8125rem] text-subtle">
            {gettext("Reading the last matches from CRCON...")}
          </span>
          <.skeleton_block :for={_ <- 1..6} class="h-8 rounded-xl" />
        <% :needs_stat -> %>
          <span class="text-[0.8125rem] text-subtle">
            {gettext("Pick the stat to see the standings.")}
          </span>
        <% %{matches: 0} -> %>
          <span class="text-[0.8125rem] leading-snug text-subtle">
            {gettext(
              "No finished match in CRCON's history for these servers yet: the preview shows up after the first ones."
            )}
          </span>
        <% preview -> %>
          <span class="-mt-1 text-[0.8125rem] leading-snug text-subtle">
            {ngettext(
              "The formula applied to the last match of %{servers}. Nothing is saved until you create it.",
              "The formula applied to the last %{count} matches of %{servers}. Nothing is saved until you create it.",
              preview.matches,
              servers: Dashboard.servers_line(@servers)
            )}
          </span>

          <div :if={@parts != []} class="flex flex-col gap-1.5">
            <span class="text-xs text-muted">{gettext("Where the score comes from")}</span>
            <div class="flex h-3 gap-0.5">
              <span
                :for={{part, index} <- Enum.with_index(@parts)}
                class={["rounded", "part-#{rem(index, 6)}"]}
                style={"flex-grow: #{part.share}"}
              ></span>
            </div>
            <div class="flex flex-wrap gap-x-3 gap-y-1 text-[0.6875rem] text-subtle">
              <span :for={part <- @parts}>{Dashboard.metric_word(part.metric)} {part.share}%</span>
            </div>
          </div>

          <div class="preview-grid border-b border-line-soft px-2 pt-1.5 pb-1 text-xs text-muted">
            <span>#</span>
            <span>{gettext("Player")}</span>
            <span class="text-right">{gettext("Matches")}</span>
            <span class="text-right">{gettext("Score")}</span>
            <span class="text-right whitespace-nowrap">{gettext("vs now")}</span>
          </div>

          <div class="-mt-1.5 flex flex-col gap-0.5">
            <%= for {row, rank} <- Enum.with_index(preview.top, 1) do %>
              <div class={[
                "preview-grid rounded-xl px-2 py-2 text-sm",
                rank == 1 && "bg-primary/6"
              ]}>
                <span class={[
                  "font-mono",
                  if(rank <= @winners, do: "text-primary", else: "text-muted")
                ]}>
                  {String.pad_leading(to_string(rank), 2, "0")}
                </span>
                <span class="truncate font-semibold">{row.name || row.player_id}</span>
                <span class="text-right font-mono text-subtle">{row.matches}</span>
                <span class="text-right font-mono">{number(row.score)}</span>
                <span class="text-right">
                  <.delta moved={vs_now(@current, row.player_id, rank)} />
                </span>
              </div>
              <div
                :if={rank == @winners and rank < length(preview.top)}
                class="flex items-center gap-2.5 px-2 py-1"
              >
                <span class="prize-line"></span>
                <span class="text-[0.6875rem] font-semibold tracking-[0.06em] text-primary uppercase">
                  {prize_label(@draft)}
                </span>
                <span class="prize-line"></span>
              </div>
            <% end %>
            <p :if={preview.top == []} class="py-3 text-xs text-muted">
              {gettext("Nobody played the minimum matches in this stretch.")}
            </p>
          </div>

          <div :if={preview.below != []} class="flex flex-col gap-1 border-t border-line-soft pt-2.5">
            <span class="text-xs text-muted">
              {ngettext(
                "Under 1 match · they show up, without a prize",
                "Under %{count} matches · they show up, without a prize",
                @draft.min_matches || 0
              )}
            </span>
            <div :for={row <- preview.below} class="preview-grid px-2 py-1.5 text-sm text-subtle">
              <span class="font-mono text-muted">—</span>
              <span class="truncate">{row.name || row.player_id}</span>
              <span class="text-right font-mono text-warning">{row.matches}</span>
              <span class="text-right font-mono">{number(row.score)}</span>
              <span></span>
            </div>
          </div>

          <div
            :if={@change}
            id="season-preview-change"
            class="flex gap-2.5 rounded-2xl border border-warning/28 bg-warning/8 px-3.5 py-3"
          >
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-warning" />
            <span class="text-[0.8125rem] leading-snug">{@change}</span>
          </div>
      <% end %>
    </aside>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp parts(%{parts: parts}) when parts != [] do
    total = parts |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> max(1)

    Enum.map(parts, fn {metric, points} ->
      %{metric: metric, share: round(points * 100 / total)}
    end)
  end

  defp parts(_preview), do: []

  defp share_of(parts, metric) do
    case Enum.find(parts, &(to_string(&1.metric) == metric)) do
      %{share: share} -> share
      nil -> 0
    end
  end

  defp metric_atom(value) do
    Enum.find(Scoring.weighted_metrics(), &(to_string(&1) == value))
  end

  defp vs_now(nil, _player_id, _rank), do: nil

  defp vs_now(%{ranks: ranks}, player_id, rank) do
    case ranks[player_id] do
      nil -> :new
      now -> now - rank
    end
  end

  # When the formula puts somebody else on top of the running season.
  defp podium_change(nil, _preview), do: nil

  defp podium_change(%{leader: leader, season: season}, %{top: [first | _rest]})
       when not is_nil(leader) do
    if first.player_id != leader.player_id do
      gettext("With this formula %{new} goes past %{leader}, who leads %{season}.",
        new: first.name || first.player_id,
        leader: leader.player_name || leader.player_id,
        season: season.name
      )
    end
  end

  defp podium_change(_current, _preview), do: nil

  defp prize_label(%{reward_vip_hours: hours}) when is_integer(hours) and hours > 0,
    do: gettext("%{hours} h of VIP", hours: hours)

  defp prize_label(_draft), do: gettext("Prize line")

  defp formula_text(draft) do
    terms =
      draft
      |> Dashboard.formula_lines()
      |> Enum.reject(& &1.dim)
      |> Enum.map_join(" + ", & &1.text)

    terms = if terms == "", do: "–", else: terms

    if draft.per_match,
      do: gettext("score = (%{terms}) ÷ matches", terms: terms),
      else: gettext("score = %{terms}", terms: terms)
  end

  defp duration_options(value) do
    current = to_int(value, 30)
    days = if current in @durations, do: @durations, else: @durations ++ [current]
    Enum.map(days, &{gettext("%{count} d", count: &1), to_string(&1)})
  end

  defp vip_hint(value) do
    hours = to_int(value, 0)
    if hours >= 24, do: "h · " <> Dashboard.vip_words(hours), else: "h"
  end

  defp scoring(form) do
    case to_string(form[:scoring].value) do
      "average" -> :average
      "weighted" -> :weighted
      "elo" -> :elo
      _sum -> :sum
    end
  end

  defp scoring_hint(:weighted),
    do: gettext("Each stat times its weight. Playing a lot is not enough to win.")

  defp scoring_hint(scoring), do: Labels.scoring_hint(scoring)

  defp errors(form, field) do
    Enum.map(form[field].errors, &translate_error/1)
  end

  defp truthy?(value), do: value in [true, "true", "on"]

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  @doc "The header line of the form: where it sits and what runs now."
  @spec crumb(map() | nil) :: String.t()
  def crumb(%{season: season}) do
    gettext("Community / Seasons · the current one, %{name}, %{ends}",
      name: season.name,
      ends: Dashboard.ends_in(season, DateTime.utc_now())
    )
  end

  def crumb(_none), do: gettext("Community / Seasons")
end
