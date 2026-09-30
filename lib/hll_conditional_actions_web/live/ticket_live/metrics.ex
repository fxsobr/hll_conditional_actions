defmodule HllConditionalActionsWeb.TicketLive.Metrics do
  @moduledoc """
  How the team handles tickets, over 7, 30 or 90 days, each figure against
  the period before: tickets per day, how long players waited for a first
  answer (median, p90 and a spread), when players call (weekday by hour),
  who answered first, the categories, who calls the most and who is
  reported the most. The rows export as CSV.

  Global under `/tickets/metrics` (every server the user sees, or the ones
  ticked), or one server's under `/servers/:server_id/tickets/metrics`. Days
  and hours follow the server's time zone, or on the global page the zone
  most of the servers use.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_tickets}}

  import Ecto.Query, only: [from: 2]

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Tickets
  alias HllConditionalActions.Tickets.Settings
  alias HllConditionalActions.Tickets.Stats
  alias HllConditionalActions.Tickets.Ticket
  alias HllConditionalActionsWeb.TicketComponents
  alias HllConditionalActionsWeb.TicketSettingsForm

  @periods [7, 30, 90]

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    servers = Servers.list_servers_for(socket.assigns.current_user)
    server = Enum.find(servers, &(to_string(&1.id) == params["server_id"]))

    if params["server_id"] && is_nil(server) do
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that page."))
       |> push_navigate(to: ~p"/tickets")}
    else
      # Ticket changes arrive through `HllConditionalActionsWeb.Nav`, which
      # subscribes every user who may read tickets.
      {:ok,
       socket
       |> assign(:page_title, gettext("Inbox"))
       |> assign(:can_manage?, Accounts.can?(socket.assigns.current_user, :manage_tickets))
       |> assign(:server, server)
       |> assign(:servers, if(server, do: [server], else: servers))
       |> assign(:selected, if(server, do: [server.id], else: Enum.map(servers, & &1.id)))
       |> assign(:readers, readers())
       |> assign(:days, 30)
       |> load()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("period", %{"days" => days}, socket) do
    days = Enum.find(@periods, 30, &(to_string(&1) == days))
    {:noreply, socket |> assign(:days, days) |> load()}
  end

  def handle_event("select_servers", params, socket) do
    allowed = MapSet.new(socket.assigns.servers, & &1.id)

    ids =
      params
      |> Map.get("server_ids", [])
      |> Enum.flat_map(&TicketSettingsForm.parse_id/1)
      |> Enum.filter(&MapSet.member?(allowed, &1))

    ids = if ids == [], do: socket.assigns.selected, else: ids
    {:noreply, socket |> assign(:selected, ids) |> load()}
  end

  # The period's tickets as CSV, handed to the browser to save.
  def handle_event("export", _params, socket) do
    {:reply, %{csv: csv(socket), filename: "tickets-#{socket.assigns.days}d.csv"}, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:ticket_changed, _ticket}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    %{selected: ids, days: days, current_user: user, servers: servers} = socket.assigns
    chosen = Enum.filter(servers, &(&1.id in ids))
    timezone = timezone(socket.assigns.server, chosen)
    settings = chosen |> List.first() |> then(&(&1 && Tickets.get_settings(&1.id)))

    socket
    |> assign(:timezone, timezone)
    |> assign(:settings, settings)
    |> assign(:metrics, Stats.metrics(user, days: days, server_ids: ids, timezone: timezone))
  end

  # Who reads tickets without answering them, for the footnote.
  defp readers do
    Accounts.list_users()
    |> Repo.preload(:role)
    |> Enum.filter(&(&1.active and Accounts.can?(&1, :view_tickets)))
    |> Enum.reject(&Accounts.can?(&1, :manage_tickets))
  end

  defp csv(socket) do
    # The ticked servers are among the ones the user sees.
    %{selected: ids, days: days} = socket.assigns
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    rows =
      Repo.all(
        from t in Ticket,
          join: s in assoc(t, :server),
          where: t.server_id in ^ids and t.inserted_at >= ^since,
          order_by: [asc: t.inserted_at],
          select: {t, s.name}
      )

    header =
      ~w(id server player_id player category priority status source opened_at first_answer_seconds closed_at close_reason reported_player)

    lines =
      Enum.map(rows, fn {ticket, server} ->
        [
          ticket.id,
          server,
          ticket.player_id,
          ticket.player_name,
          ticket.category,
          ticket.priority,
          ticket.status,
          ticket.source,
          ticket.inserted_at && DateTime.to_iso8601(ticket.inserted_at),
          ticket.first_response_at && DateTime.diff(ticket.first_response_at, ticket.inserted_at),
          ticket.closed_at && DateTime.to_iso8601(ticket.closed_at),
          ticket.close_reason,
          ticket.reported_player_name
        ]
      end)

    Enum.map_join([header | lines], "\r\n", fn row -> Enum.map_join(row, ",", &csv_cell/1) end)
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(value) do
    text = to_string(value)

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  @doc """
  The time zone the hours are shown in: the server's, or the one most of the
  servers use when looking at several.

      iex> alias HllConditionalActionsWeb.TicketLive.Metrics
      iex> servers = [%{timezone: "America/Sao_Paulo"}, %{timezone: "America/Sao_Paulo"}, %{timezone: "Europe/Paris"}]
      iex> Metrics.timezone(nil, servers)
      "America/Sao_Paulo"
      iex> Metrics.timezone(%{timezone: "Europe/Paris"}, servers)
      "Europe/Paris"
      iex> Metrics.timezone(nil, [])
      "Etc/UTC"
  """
  @spec timezone(map() | nil, [map()]) :: String.t()
  def timezone(%{timezone: zone}, _servers) when is_binary(zone) and zone != "", do: zone

  def timezone(_server, servers) do
    servers
    |> Enum.map(& &1.timezone)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_zone, count} -> count end, fn -> {"Etc/UTC", 0} end)
    |> elem(0)
  end

  @doc """
  A duration in seconds, the way an admin says it.

      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(nil)
      "–"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(42.4)
      "42 s"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(160)
      "2 min 40 s"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(660)
      "11 min"
      iex> HllConditionalActionsWeb.TicketLive.Metrics.duration(7260)
      "2 h 01 min"
  """
  @spec duration(number() | nil) :: String.t()
  def duration(nil), do: "–"

  def duration(seconds) do
    seconds = round(seconds)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    cond do
      seconds < 60 -> "#{seconds} s"
      seconds < 3600 and rem(seconds, 60) == 0 -> "#{div(seconds, 60)} min"
      seconds < 600 -> "#{div(seconds, 60)} min #{pad.(rem(seconds, 60))} s"
      seconds < 3600 -> "#{div(seconds, 60)} min"
      true -> "#{div(seconds, 3600)} h #{pad.(div(rem(seconds, 3600), 60))} min"
    end
  end

  @doc """
  A round top for the per-day chart's axis.

      iex> Enum.map([0, 3, 15, 23, 140], &HllConditionalActionsWeb.TicketLive.Metrics.axis_top/1)
      [2, 4, 16, 30, 150]
  """
  @spec axis_top(non_neg_integer()) :: pos_integer()
  def axis_top(max) when max <= 2, do: 2
  def axis_top(max) when max <= 20, do: ceil(max / 2) * 2
  def axis_top(max) when max <= 100, do: ceil(max / 10) * 10
  def axis_top(max), do: ceil(max / 50) * 50

  @doc """
  The busiest block of four hours, as `{days, from_hour}`: the weekday and
  window with the most calls, plus the other days that come within 80% of
  it in the same window.
  """
  @spec peak(map()) :: {[1..7], 0..23} | nil
  def peak(heatmap) when map_size(heatmap) == 0, do: nil

  def peak(heatmap) do
    window = fn day, hour ->
      Enum.sum(for h <- hour..(hour + 3), do: Map.get(heatmap, {day, rem(h, 24)}, 0))
    end

    {{day, hour}, best} =
      for(day <- 1..7, hour <- 0..23, do: {{day, hour}, window.(day, hour)})
      |> Enum.max_by(&elem(&1, 1))

    days =
      Enum.filter(1..7, fn other -> other == day or window.(other, hour) >= best * 0.8 end)

    {days, hour}
  end

  # ── Render helpers ─────────────────────────────────────────────────────────

  defp delta_label(%{total: total, previous_total: previous, days: days, first_day: first}) do
    if previous > 0 do
      pct = round((total - previous) / previous * 100)
      arrow = if pct >= 0, do: "↑", else: "↓"
      "#{arrow} #{abs(pct)}% " <> previous_period(days, first)
    end
  end

  defp previous_period(7, _first), do: gettext("over the week before")

  defp previous_period(30, first) do
    middle = Date.add(first, -15)
    gettext("over %{month}", month: month_name(middle.month))
  end

  defp previous_period(days, _first), do: gettext("over the %{days} days before", days: days)

  defp month_name(month) do
    Enum.at(
      [
        gettext("January"),
        gettext("February"),
        gettext("March"),
        gettext("April"),
        gettext("May"),
        gettext("June"),
        gettext("July"),
        gettext("August"),
        gettext("September"),
        gettext("October"),
        gettext("November"),
        gettext("December")
      ],
      month - 1
    )
  end

  # The month's first three letters, in the reader's language ("ago", "Aug").
  defp short_month(month), do: month |> month_name() |> String.slice(0, 3) |> String.downcase()

  defp day_label(date), do: "#{date.day} #{short_month(date.month)}"

  # Five labels under the per-day chart: the first day, three between, today.
  defp axis_days(per_day) do
    count = length(per_day)

    if count < 2 do
      []
    else
      Enum.map(0..4, fn step -> Enum.at(per_day, round(step * (count - 1) / 4)) |> elem(0) end)
      |> Enum.uniq()
    end
  end

  defp heat_level(0, _max), do: 0

  defp heat_level(count, max) do
    share = count / max(max, 1)

    cond do
      share <= 0.25 -> 1
      share <= 0.5 -> 2
      share <= 0.75 -> 3
      true -> 4
    end
  end

  defp bucket_label(:under_1), do: gettext("< 1 min")
  defp bucket_label(:from_1_to_3), do: gettext("1–3 min")
  defp bucket_label(:from_3_to_5), do: gettext("3–5 min")
  defp bucket_label(:from_5_to_15), do: gettext("5–15 min")
  defp bucket_label(:over_15), do: gettext("> 15 min")

  # "35 s faster" / "1 min slower", against the period before.
  defp change(nil, _before), do: nil
  defp change(_now, nil), do: nil

  defp change(now, before) do
    diff = now - before

    cond do
      diff < 0 -> {:better, gettext("%{time} faster", time: duration(-diff))}
      diff > 0 -> {:worse, gettext("%{time} slower", time: duration(diff))}
      true -> {:same, gettext("same as before")}
    end
  end

  defp peak_text(nil, _settings), do: nil

  defp peak_text({days, hour}, settings) do
    days_text =
      days
      |> Enum.map(&String.downcase(weekday_long(&1)))
      |> join_and()

    peak =
      gettext("Peak: %{days} from %{from} to %{to}.",
        days: days_text,
        from: "#{hour}h",
        to: "#{rem(hour + 4, 24)}h"
      )

    coverage =
      if settings && settings.hours_enabled do
        hours = TicketSettingsForm.rows(settings).hours

        if hours == %{},
          do: "",
          else:
            " " <> gettext("Office hours: %{hours}.", hours: TicketSettingsForm.summary(hours))
      else
        ""
      end

    peak <> coverage
  end

  defp join_and([one]), do: one

  defp join_and(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " " <> gettext("and") <> " " <> last
  end

  defp weekday_long(1), do: gettext("Monday")
  defp weekday_long(2), do: gettext("Tuesday")
  defp weekday_long(3), do: gettext("Wednesday")
  defp weekday_long(4), do: gettext("Thursday")
  defp weekday_long(5), do: gettext("Friday")
  defp weekday_long(6), do: gettext("Saturday")
  defp weekday_long(7), do: gettext("Sunday")

  defp category_color(nil, _settings), do: "gray"

  defp category_color(name, settings) do
    with %Settings{} <- settings,
         found when is_binary(found) <- Settings.find_category(settings, name),
         %{color: color} <-
           Enum.find(Settings.category_list(settings), &(&1.name == found)) do
      color
    else
      _other -> "gray"
    end
  end

  defp category_name(nil), do: gettext("No category")
  defp category_name(name), do: TicketComponents.ticket_title(%{category: name})

  defp servers_label(servers, selected) do
    case Enum.filter(servers, &(&1.id in selected)) do
      [] -> gettext("No server")
      [server] -> server.name
      [one, two] -> gettext("%{one} and %{two}", one: one.name, two: two.name)
      several -> ngettext("1 server", "%{count} servers", length(several))
    end
  end

  defp readers_text([]), do: nil

  defp readers_text([user]) do
    gettext("%{name} is %{role} and does not answer tickets.",
      name: user.name || user.username,
      role: (user.role && user.role.name) || gettext("a reader")
    )
  end

  defp readers_text(users),
    do:
      gettext("%{names} read tickets without answering them.",
        names: users |> Enum.map(&(&1.name || &1.username)) |> join_and()
      )

  defp unanswered_reason(nil), do: gettext("no answer")
  defp unanswered_reason(reason), do: String.downcase(Labels.close_reason(reason))

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    metrics = assigns.metrics
    day_max = metrics.per_day |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    top = axis_top(day_max)
    heat_max = metrics.heatmap |> Map.values() |> Enum.max(fn -> 0 end)
    bucket_max = metrics.first_response.buckets |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

    responder_max =
      Enum.max(
        [1 | Enum.map(metrics.responders, & &1.count)] ++
          [metrics.auto_answered, metrics.unanswered.count]
      )

    today_weekday = Date.day_of_week(metrics.today)

    assigns =
      assigns
      |> assign(:day_max, day_max)
      |> assign(:top, top)
      |> assign(:heat_max, heat_max)
      |> assign(:bucket_max, max(bucket_max, 1))
      |> assign(:responder_max, responder_max)
      |> assign(:today_weekday, today_weekday)
      |> assign(:category_total, max(Enum.sum(Enum.map(metrics.categories, &elem(&1, 1))), 1))
      |> assign(
        :settings_path,
        if(assigns.server,
          do: ~p"/servers/#{assigns.server.id}/tickets/settings",
          else: ~p"/tickets/settings"
        )
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
        <form id="metrics-period" phx-change="period">
          <div
            role="radiogroup"
            aria-label={gettext("Period")}
            class="flex gap-1 rounded-full border border-base-300 bg-base-100 p-1"
          >
            <label :for={days <- [7, 30, 90]} class="cursor-pointer">
              <input
                type="radio"
                name="days"
                value={days}
                checked={@days == days}
                class="peer sr-only"
              />
              <span class="flex h-[2.375rem] items-center whitespace-nowrap rounded-full px-3.5 text-[0.8125rem] text-subtle peer-checked:bg-base-content peer-checked:font-semibold peer-checked:text-base-100">
                {gettext("%{count} days", count: days)}
              </span>
            </label>
          </div>
        </form>

        <details :if={is_nil(@server)} id="metrics-servers" class="relative">
          <summary class="flex h-12 cursor-pointer list-none items-center gap-2.5 rounded-full border border-base-300 bg-base-100 pl-1.5 pr-4 text-sm font-medium [&::-webkit-details-marker]:hidden">
            <span class="flex size-9 items-center justify-center rounded-full bg-secondary text-[0.8125rem] font-bold">
              {length(@selected)}
            </span>
            {servers_label(@servers, @selected)}
            <.icon name="hero-chevron-down" class="size-4 text-muted" />
          </summary>
          <form
            id="metrics-server-picker"
            phx-change="select_servers"
            class="absolute right-0 top-full z-30 mt-2 flex w-64 flex-col gap-1 rounded-2xl border border-base-300 bg-base-100 p-2 shadow-lg"
          >
            <label
              :for={server <- @servers}
              class="flex cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-2 text-sm hover:bg-secondary"
            >
              <input
                type="checkbox"
                name="server_ids[]"
                value={server.id}
                checked={server.id in @selected}
                class="size-4 accent-[var(--color-primary)]"
              />
              <span class="truncate">{server.name}</span>
            </label>
          </form>
        </details>

        <button
          type="button"
          id="metrics-export"
          phx-hook=".CsvExport"
          class="h-12 cursor-pointer rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:border-base-content/30"
        >
          {gettext("Export CSV")}
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CsvExport">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                this.pushEvent("export", {}, ({csv, filename}) => {
                  const url = URL.createObjectURL(new Blob(["﻿" + csv], {type: "text/csv;charset=utf-8"}))
                  const link = document.createElement("a")
                  link.href = url
                  link.download = filename
                  link.click()
                  URL.revokeObjectURL(url)
                })
              })
            }
          }
        </script>
      </:actions>

      <div class="grid grid-cols-[minmax(0,1fr)] gap-5 md:mt-4 min-[80rem]:min-h-[calc(100dvh-8.75rem)] lg:grid-cols-[minmax(0,1fr)_26.25rem] lg:grid-rows-[17.625rem_18.75rem_1fr]">
        <section
          id="metrics-per-day"
          aria-label={gettext("Tickets per day")}
          class="inbox-panel flex min-h-0 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex flex-wrap items-baseline gap-x-3.5 gap-y-1">
            <h2 class="font-display text-[1.25rem] font-semibold">{gettext("Tickets per day")}</h2>
            <strong id="metrics-total" class="font-display text-[1.25rem] font-semibold">{@metrics.total}</strong>
            <span :if={delta_label(@metrics)} class="text-[0.8125rem] text-primary">
              {delta_label(@metrics)}
            </span>
            <span class="flex-1"></span>
            <span :if={@metrics.busiest_weekday} class="text-xs text-muted">
              {gettext("%{day} takes 1 in every %{count}",
                day: TicketSettingsForm.weekday(@metrics.busiest_weekday.weekday),
                count: @metrics.busiest_weekday.one_in
              )}
            </span>
          </div>
          <div class="grid min-h-40 flex-1 grid-cols-[1.625rem_minmax(0,1fr)] gap-2">
            <div class="flex flex-col justify-between pb-[1.375rem] text-right font-mono text-[0.625rem] text-muted">
              <span>{@top}</span><span>{div(@top, 2)}</span><span>0</span>
            </div>
            <div class="flex min-h-0 flex-col gap-1.5">
              <div
                role="img"
                aria-label={gettext("Tickets opened per day")}
                class={[
                  "relative flex flex-1 items-end border-b border-base-300",
                  if(@days > 30, do: "gap-0.5", else: "gap-1")
                ]}
              >
                <span class="absolute inset-x-0 top-0 border-t border-dashed border-(--inbox-line)"></span>
                <span class="absolute inset-x-0 top-1/2 border-t border-dashed border-(--inbox-line)"></span>
                <span
                  :for={{{date, count}, index} <- Enum.with_index(@metrics.per_day)}
                  title={"#{day_label(date)}: #{count}"}
                  class={[
                    "relative flex-1 rounded-t",
                    if(index == length(@metrics.per_day) - 1,
                      do: "border-[1.5px] border-b-0 border-dashed border-primary bg-primary/14",
                      else: "bg-primary"
                    )
                  ]}
                  style={"height: #{if count == 0, do: 0, else: max(2, round(count / @top * 100))}%"}
                >
                  <span
                    :if={
                      count > 0 and
                        (index == length(@metrics.per_day) - 1 or count == @day_max)
                    }
                    class="absolute bottom-full left-1/2 -translate-x-1/2 pb-1 font-mono text-[0.6875rem]"
                  >
                    {count}
                  </span>
                </span>
              </div>
              <div class="flex justify-between font-mono text-[0.6875rem] text-muted">
                <span
                  :for={date <- axis_days(@metrics.per_day)}
                  class={date == @metrics.today && "text-base-content"}
                >
                  {if date == @metrics.today, do: gettext("today"), else: day_label(date)}
                </span>
              </div>
            </div>
          </div>
        </section>

        <section
          id="metrics-first-response"
          aria-label={gettext("First answer")}
          class="inbox-panel flex min-h-0 flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-6 py-5"
        >
          <div class="flex items-baseline">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("First answer")}
            </h2>
            <span class="text-xs text-muted">{gettext("within office hours")}</span>
          </div>
          <div class="grid grid-cols-2 gap-2.5">
            <div
              :for={
                {label, value, before} <- [
                  {gettext("Median"), @metrics.first_response.median,
                   @metrics.first_response.previous_median},
                  {"p90", @metrics.first_response.p90, @metrics.first_response.previous_p90}
                ]
              }
              class="flex flex-col gap-0.5 rounded-[1.125rem] bg-secondary px-3.5 py-3"
            >
              <span class="text-xs text-subtle">{label}</span>
              <strong class="font-display text-[1.625rem] font-semibold leading-tight">{duration(
                value
              )}</strong>
              <span
                :if={change(value, before)}
                class={[
                  "text-xs",
                  case change(value, before) do
                    {:better, _text} -> "text-primary"
                    {:worse, _text} -> "text-warning"
                    _same -> "text-muted"
                  end
                ]}
              >
                {elem(change(value, before), 1)}
              </span>
            </div>
          </div>
          <div class="flex flex-col gap-1.5">
            <div
              :for={{key, count} <- @metrics.first_response.buckets}
              class="grid grid-cols-[4.375rem_minmax(0,1fr)_1.75rem] items-center gap-2.5 text-xs"
            >
              <span class="text-subtle">{bucket_label(key)}</span>
              <span class="flex h-2 rounded bg-secondary">
                <span
                  class={["rounded", if(key == :over_15, do: "bg-warning", else: "bg-primary")]}
                  style={"width: #{round(count / @bucket_max * 100)}%"}
                ></span>
              </span>
              <span class="text-right font-mono">{count}</span>
            </div>
          </div>
        </section>

        <section
          id="metrics-heatmap"
          aria-label={gettext("Calls per hour")}
          class="inbox-panel flex min-h-0 flex-col gap-3 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex items-center gap-3">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("Calls per hour")}
            </h2>
            <span class="text-xs text-muted">{gettext("fewer")}</span>
            <span class="flex gap-[3px]" aria-hidden="true">
              <span :for={level <- 0..4} class={["size-3.5 rounded", "inbox-heat-#{level}"]}></span>
            </span>
            <span class="text-xs text-muted">{gettext("more")}</span>
          </div>
          <div class="flex flex-col gap-1">
            <div
              :for={day <- 1..7}
              class="grid h-5 grid-cols-[2.125rem_repeat(24,minmax(0,1fr))] gap-1"
            >
              <span class={[
                "self-center text-xs",
                if(day == @today_weekday, do: "font-semibold text-base-content", else: "text-subtle")
              ]}>
                {TicketSettingsForm.weekday(day)}
              </span>
              <span
                :for={hour <- 0..23}
                title={"#{TicketSettingsForm.weekday(day)} #{hour}h: #{Map.get(@metrics.heatmap, {day, hour}, 0)}"}
                class={[
                  "rounded",
                  "inbox-heat-#{heat_level(Map.get(@metrics.heatmap, {day, hour}, 0), @heat_max)}"
                ]}
              ></span>
            </div>
            <div class="mt-0.5 grid grid-cols-[2.125rem_repeat(8,minmax(0,1fr))] gap-1 font-mono text-[0.625rem] text-muted">
              <span></span>
              <span :for={hour <- [0, 3, 6, 9, 12, 15, 18, 21]}>{hour}h</span>
            </div>
          </div>
          <span :if={peak_text(peak(@metrics.heatmap), @settings)} class="text-xs text-muted">
            {peak_text(peak(@metrics.heatmap), @settings)}
          </span>
        </section>

        <section
          id="metrics-responders"
          aria-label={gettext("Who answered")}
          class="inbox-panel flex min-h-0 flex-col gap-3 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex items-baseline">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("Who answered")}
            </h2>
            <span class="text-xs text-muted">{gettext("first answer")}</span>
          </div>
          <div class="flex flex-col gap-2">
            <div
              :for={row <- Enum.take(@metrics.responders, 2)}
              class="grid grid-cols-[2rem_minmax(0,1fr)_2.25rem] items-center gap-2.5"
            >
              <TicketComponents.avatar_tile
                name={row.name}
                tone={if row.user_id == @current_user.id, do: "olive", else: "engine"}
                size="xs"
              />
              <span class="flex min-w-0 flex-col gap-[5px]">
                <span class="flex justify-between gap-2 text-[0.8125rem]">
                  <span class="truncate">
                    {row.name}{if row.user_id == @current_user.id, do: " " <> gettext("(you)")}
                  </span>
                  <span class="shrink-0 text-muted">
                    {gettext("median %{time}", time: duration(row.median))}
                  </span>
                </span>
                <span class="flex h-2 rounded bg-secondary">
                  <span
                    class="rounded bg-primary"
                    style={"width: #{round(row.count / @responder_max * 100)}%"}
                  ></span>
                </span>
              </span>
              <span class="text-right font-mono text-[0.8125rem]">{row.count}</span>
            </div>
            <div class="grid grid-cols-[2rem_minmax(0,1fr)_2.25rem] items-center gap-2.5">
              <span class="flex size-8 items-center justify-center rounded-[0.625rem] bg-secondary text-subtle">
                <.icon name="hero-clock" class="size-4" />
              </span>
              <span class="flex min-w-0 flex-col gap-[5px]">
                <span class="flex justify-between gap-2 text-[0.8125rem]">
                  <span class="truncate">{gettext("Answer outside office hours")}</span>
                  <span class="shrink-0 text-muted">{gettext("automatic")}</span>
                </span>
                <span class="flex h-2 rounded bg-secondary">
                  <span
                    class="rounded bg-muted"
                    style={"width: #{round(@metrics.auto_answered / @responder_max * 100)}%"}
                  ></span>
                </span>
              </span>
              <span class="text-right font-mono text-[0.8125rem]">{@metrics.auto_answered}</span>
            </div>
            <div class="grid grid-cols-[2rem_minmax(0,1fr)_2.25rem] items-center gap-2.5">
              <span class="flex size-8 items-center justify-center rounded-[0.625rem] bg-warning/13 text-warning">
                <.icon name="hero-exclamation-triangle" class="size-4" />
              </span>
              <span class="flex min-w-0 flex-col gap-[5px]">
                <span class="flex justify-between gap-2 text-[0.8125rem]">
                  <span class="truncate">{gettext("Closed without an answer")}</span>
                  <span class="shrink-0 text-warning">{unanswered_reason(@metrics.unanswered.reason)}</span>
                </span>
                <span class="flex h-2 rounded bg-secondary">
                  <span
                    class="rounded bg-warning"
                    style={"width: #{round(@metrics.unanswered.count / @responder_max * 100)}%"}
                  ></span>
                </span>
              </span>
              <span class="text-right font-mono text-[0.8125rem]">{@metrics.unanswered.count}</span>
            </div>
          </div>
          <span class="flex-1"></span>
          <span :if={readers_text(@readers)} class="text-xs text-muted">{readers_text(@readers)}</span>
        </section>

        <section
          id="metrics-categories"
          aria-label={gettext("By category")}
          class="inbox-panel flex min-h-0 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex items-baseline">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">{gettext("By category")}</h2>
            <.link
              :if={@can_manage?}
              navigate={@settings_path}
              class="text-[0.8125rem] text-primary hover:underline"
            >
              {gettext("Edit categories")}
            </.link>
          </div>
          <p :if={@metrics.categories == []} class="text-sm text-muted">
            {gettext("No tickets in this period.")}
          </p>
          <div
            :if={@metrics.categories != []}
            role="img"
            aria-label={
              Enum.map_join(@metrics.categories, ", ", fn {name, count} ->
                "#{category_name(name)} #{count}"
              end)
            }
            class="flex h-3.5 gap-0.5 overflow-hidden rounded"
          >
            <span
              :for={{name, count} <- @metrics.categories}
              class={["inbox-swatch", "inbox-color-#{category_color(name, @settings)}"]}
              style={"width: #{Float.round(count / @category_total * 100, 1)}%"}
            ></span>
          </div>
          <div class="grid grid-cols-2 gap-x-5 gap-y-2.5 sm:grid-cols-3">
            <div
              :for={{name, count} <- Enum.take(@metrics.categories, 5)}
              class="flex flex-col gap-0.5"
            >
              <span class={[
                "flex items-center gap-2 text-[0.8125rem] text-subtle",
                "inbox-color-#{category_color(name, @settings)}"
              ]}>
                <span class="inbox-swatch size-2.5 shrink-0 rounded-[3px]"></span>
                <span class="truncate">{category_name(name)}</span>
              </span>
              <span class="flex items-baseline gap-2">
                <strong class="font-display text-[1.375rem] font-semibold">{count}</strong>
                <span class="text-xs text-muted">{round(count / @category_total * 100)}%</span>
              </span>
            </div>
            <div :if={@metrics.category_growth} class="flex flex-col justify-end">
              <span class="text-xs leading-snug text-muted">
                {gettext("%{category} grew by %{count} over the period before.",
                  category: category_name(elem(@metrics.category_growth, 0)),
                  count: elem(@metrics.category_growth, 1)
                )}
              </span>
            </div>
          </div>
        </section>

        <section
          id="metrics-top-players"
          aria-label={gettext("Who calls the most")}
          class="inbox-panel flex min-h-0 flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
        >
          <div class="flex items-baseline">
            <h2 class="flex-1 font-display text-[1.25rem] font-semibold">
              {gettext("Who calls the most")}
            </h2>
            <span class="text-xs text-muted">{gettext("tickets")}</span>
          </div>
          <p :if={@metrics.top_players == []} class="text-sm text-muted">
            {gettext("No tickets in this period.")}
          </p>
          <.link
            :for={{row, rank} <- Enum.with_index(@metrics.top_players, 1)}
            navigate={~p"/players/#{row.player_id}"}
            class="grid grid-cols-[1.375rem_minmax(0,1fr)_auto] items-center gap-2.5 py-[5px] text-[0.8125rem]"
          >
            <span class="font-mono text-muted">{rank}</span>
            <span class="truncate">
              <strong class="font-semibold">{row.name}</strong>
              <span :if={row.category} class="text-muted">
                · {gettext("%{count} about %{category}",
                  count: row.in_category,
                  category: category_name(row.category)
                )}
              </span>
            </span>
            <span class="font-mono">{row.count}</span>
          </.link>
          <div
            :if={@metrics.most_cited}
            id="metrics-most-cited"
            class="inbox-cited mt-1 flex items-center gap-3 rounded-2xl border px-3.5 py-3"
          >
            <TicketComponents.avatar_tile name={@metrics.most_cited.name} tone="axis" size="xs" />
            <span class="flex min-w-0 flex-1 flex-col gap-0.5">
              <span class="truncate text-[0.8125rem]">
                {gettext("%{player} is the most reported", player: @metrics.most_cited.name)}
              </span>
              <span class="inbox-cited-text text-xs">
                {ngettext("1 ticket", "%{count} tickets", @metrics.most_cited.tickets)} · {ngettext(
                  "from 1 player",
                  "from %{count} different players",
                  @metrics.most_cited.callers
                )}
              </span>
            </span>
            <.link
              navigate={~p"/players/#{@metrics.most_cited.player_id}"}
              class="shrink-0 text-[0.8125rem] text-axis hover:underline"
            >
              {gettext("See profile")}
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
