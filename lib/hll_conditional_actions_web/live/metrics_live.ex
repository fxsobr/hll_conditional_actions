defmodule HllConditionalActionsWeb.MetricsLive do
  @moduledoc """
  What the engine did in the last hour, read from
  `HllConditionalActions.Metrics.History`.

  Answers the questions you have when something looks wrong: are events
  arriving from every server, are rules firing or being skipped (and why),
  how long a rule takes to act, which CRCON calls are slow or failing, and
  whether each server's log stream is holding. Everything lives in memory and
  starts over when the application restarts or the counters are reset.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  import Ecto.Query, only: [from: 2]

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Metrics
  alias HllConditionalActions.Metrics.History
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Rules.Rule
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server
  alias HllConditionalActionsWeb.CommunityComponents

  @refresh_ms 2_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_ms, :refresh)
      LogStream.subscribe_status()
    end

    servers = Servers.list_servers()

    socket =
      socket
      |> assign(:page_title, gettext("Engine metrics"))
      |> assign(:paused?, false)
      |> assign(:crcon_server, :all)
      |> assign(:servers, servers)
      |> assign(:zone, zone(servers))
      |> assign(:stream_info, %{})
      |> load()

    {:ok, if(connected?(socket), do: fetch_stream_info(socket), else: socket)}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, %{assigns: %{paused?: true}} = socket), do: {:noreply, socket}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  def handle_info({:crcon_stream_status, server_id, {:error, _reason}}, socket) do
    {:noreply, fetch_stream_info(socket, [server_id])}
  end

  def handle_info({:crcon_stream_status, server_id, :connected}, socket) do
    {:noreply, update(socket, :stream_info, &Map.delete(&1, server_id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("toggle_refresh", _params, socket) do
    socket = update(socket, :paused?, &(not &1))
    {:noreply, if(socket.assigns.paused?, do: socket, else: load(socket))}
  end

  def handle_event("reset", _params, socket) do
    :ok = Metrics.reset()

    {:noreply, socket |> put_flash(:info, gettext("Counters reset.")) |> load()}
  end

  def handle_event("crcon_server", %{"id" => "all"}, socket) do
    {:noreply, socket |> assign(:crcon_server, :all) |> load()}
  end

  def handle_event("crcon_server", %{"id" => id}, socket) do
    server = Enum.find(socket.assigns.servers, &(to_string(&1.id) == id))
    {:noreply, socket |> assign(:crcon_server, if(server, do: server.id, else: :all)) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_async({:stream_info, server_id}, {:ok, info}, socket) do
    {:noreply, update(socket, :stream_info, &Map.put(&1, server_id, info))}
  end

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  # ── Loading ────────────────────────────────────────────────────────────────

  defp load(socket) do
    History.ensure()
    now = History.now_ms()
    servers = socket.assigns.servers
    all_calls = History.crcon_calls(:all, now)
    streams = streams(servers, now)

    calls =
      if socket.assigns.crcon_server == :all,
        do: all_calls,
        else: History.crcon_calls(socket.assigns.crcon_server, now)

    socket
    |> assign(:now, DateTime.from_unix!(now, :millisecond))
    |> assign(:now_ms, now)
    |> assign(:started_at, Metrics.snapshot().started_at)
    |> assign(:events, History.events(30, now))
    |> assign(:rules, History.rules(now))
    |> assign(:latency, History.latency(now))
    |> assign(:queue, History.queue())
    |> assign(:calls, calls)
    |> assign(:call_total, calls |> Enum.map(& &1.calls) |> Enum.sum())
    |> assign(:crcon_servers, crcon_servers(servers, History.crcon_servers(now)))
    |> assign(:insight, insight(all_calls, servers))
    |> assign(:skips, skips(History.skips(now)))
    |> assign(:log_streams, streams)
  end

  defp streams(servers, now) do
    for %Server{enabled: true, log_stream_enabled: true} = server <- servers do
      %{server: server, timeline: History.stream_timeline(server.id, now)}
    end
  end

  # The error and the next retry of the streams that are down, asked of each
  # stream process off the LiveView: a stream busy connecting answers late.
  defp fetch_stream_info(socket, ids \\ nil) do
    ids = ids || for %{server: s, timeline: t} <- socket.assigns.log_streams, down?(t), do: s.id

    Enum.reduce(ids, socket, fn id, socket ->
      start_async(socket, {:stream_info, id}, fn -> stream_info(id) end)
    end)
  end

  defp stream_info(server_id) do
    reason =
      case LogStream.status(server_id) do
        {:error, reason} -> reason
        _other -> nil
      end

    %{reason: reason, next_at: next_retry_at(server_id)}
  end

  # The stream schedules its retry with the backoff it had, then doubles it
  # (capped at 30 s). So the retry is due one "previous backoff" after the
  # failure it just reported.
  defp next_retry_at(server_id) do
    %{backoff: backoff} = :sys.get_state(LogStream.via(server_id), 1_000)
    used = if backoff >= 30_000, do: 30_000, else: div(backoff, 2)

    case History.last_status(server_id) do
      {at, :error} -> at + used
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp skips(rows) do
    ids = rows |> Enum.map(& &1.top_rule_id) |> Enum.filter(&is_integer/1)

    rules =
      if ids == [] do
        %{}
      else
        from(r in Rule, where: r.id in ^ids, select: {r.id, {r.name, r.cooldown_seconds}})
        |> Repo.all()
        |> Map.new()
      end

    total = rows |> Enum.map(& &1.count) |> Enum.sum()

    Enum.map(rows, fn row ->
      {name, cooldown} =
        Map.get(rules, row.top_rule_id, {History.rule_name(row.top_rule_id), 0})

      row
      |> Map.put(:share, if(total > 0, do: row.count / total * 100, else: 0))
      |> Map.put(:rule_name, name)
      |> Map.put(:cooldown, cooldown)
    end)
  end

  defp crcon_servers(servers, called) do
    Enum.filter(servers, &(&1.id in called))
  end

  # A 403 names the permission the key lacks; say which, for the worst one.
  defp insight(calls, servers) do
    calls
    |> Enum.flat_map(fn row ->
      for %{kind: {:status, 403}, server_id: server_id, count: count} <- row.error_breakdown,
          do: {row.endpoint, server_id, count}
    end)
    |> Enum.max_by(&elem(&1, 2), fn -> nil end)
    |> case do
      nil ->
        nil

      {endpoint, server_id, _count} ->
        server = Enum.find(servers, &(&1.id == server_id))
        permission = permission_for(endpoint)

        %{
          endpoint: endpoint,
          server: server,
          permission:
            if(permission && not (server && permission in server.known_permissions),
              do: permission
            )
        }
    end
  end

  # The CRCON permission each endpoint this app calls needs.
  @permissions %{
    "message_player" => "can_message_players",
    "message_all_players" => "can_message_players",
    "punish" => "can_punish_players",
    "kick" => "can_kick_players",
    "temp_ban" => "can_temp_ban_players",
    "perma_ban" => "can_perma_ban_players",
    "switch_player_now" => "can_switch_players_immediately",
    "switch_player_on_death" => "can_switch_players_on_death",
    "flag_player" => "can_flag_player",
    "unflag_player" => "can_unflag_player",
    "watch_player" => "can_add_player_watch",
    "unwatch_player" => "can_remove_player_watch",
    "set_broadcast" => "can_change_broadcast_message",
    "set_welcome_message" => "can_change_welcome_message",
    "add_vip" => "can_add_vip",
    "remove_vip" => "can_remove_vip",
    "get_detailed_players" => "can_view_detailed_players",
    "get_gamestate" => "can_view_gamestate",
    "get_player_profile" => "can_view_player_profile",
    "get_vip_ids" => "can_view_vip_ids",
    "get_status" => "can_view_get_status"
  }

  defp permission_for(endpoint), do: Map.get(@permissions, endpoint)

  # ── Formatting ─────────────────────────────────────────────────────────────

  defp zone(servers) do
    case servers do
      [server | _rest] -> Server.timezone(server)
      [] -> "Etc/UTC"
    end
  end

  defp local(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _error -> at
    end
  end

  defp hhmm(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  defp hhmmss(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M:%S")

  defp crumb(nil, _now, _zone), do: gettext("Settings / System")

  defp crumb(started_at, now, zone) do
    if DateTime.to_date(local(started_at, zone)) == DateTime.to_date(local(now, zone)) do
      gettext("Settings / System · counters since %{time} today", time: hhmm(started_at, zone))
    else
      gettext("Settings / System · counters since %{date} at %{time}",
        date: started_at |> local(zone) |> Calendar.strftime("%d/%m"),
        time: hhmm(started_at, zone)
      )
    end
  end

  defp int(value), do: CommunityComponents.number(value)

  defp short_name(nil), do: gettext("no server")

  defp short_name(%Server{name: name}) do
    case Regex.run(~r/^(.*?#\s*\d+)/u, name || "") do
      [_match, short] -> short
      nil -> name
    end
  end

  defp server_short(servers, id), do: short_name(Enum.find(servers, &(&1.id == id)))

  # 38 → {"38", "ms"}; 1180 → {"1,2", "s"}.
  defp duration_parts(nil), do: {"–", nil}
  defp duration_parts(ms) when ms >= 1_000, do: {CommunityComponents.decimal(ms / 1000, 1), "s"}
  defp duration_parts(ms), do: {int(round(ms)), "ms"}

  defp ms_label(nil), do: "–"
  defp ms_label(ms), do: "#{int(round(ms))} ms"

  defp share_label(share) when share > 0 and share < 2,
    do: CommunityComponents.decimal(share, 1) <> "%"

  defp share_label(share), do: "#{round(share)}%"

  defp change_label(change) do
    sign = if change >= 0, do: "+", else: "−"
    gettext("%{change}% in the last hour", change: sign <> to_string(round(abs(change))))
  end

  defp action_share(%{fired: fired, skipped: skipped}) when fired + skipped > 0,
    do: CommunityComponents.decimal(fired / (fired + skipped) * 100, 1)

  defp action_share(_rules), do: "0"

  # Where a latency sits on a log scale from 1 ms to 10 s, in percent.
  defp log_position(nil), do: 0
  defp log_position(ms), do: min(max(:math.log10(max(ms, 1)) / 4 * 100, 0), 100)

  defp latency_segments(latency) do
    p50 = log_position(latency.p50)
    p95 = log_position(latency.p95)
    p99 = log_position(latency.p99)

    [
      {0, p50, "bg-primary"},
      {p50, p95 - p50, "bg-primary/50"},
      {p95, p99 - p95, "bg-warning"}
    ]
  end

  defp trigger_context(:match_end), do: gettext("at match end")
  defp trigger_context(:match_start), do: gettext("at match start")
  defp trigger_context(:periodic), do: gettext("on scheduled sweeps")
  defp trigger_context(nil), do: nil

  defp trigger_context(trigger) do
    gettext("on “%{trigger}”", trigger: Labels.trigger(trigger))
  rescue
    FunctionClauseError -> nil
  end

  defp latency_class(nil), do: nil
  defp latency_class(ms) when ms >= 3_000, do: "text-error"
  defp latency_class(ms) when ms >= 1_000, do: "text-warning"
  defp latency_class(_ms), do: nil

  defp latency_bar(nil), do: "bg-primary/50"
  defp latency_bar(ms) when ms >= 3_000, do: "bg-error"
  defp latency_bar(ms) when ms >= 1_000, do: "bg-warning"
  defp latency_bar(_ms), do: "bg-primary/50"

  defp relative(nil, _max), do: 0
  defp relative(_p95, max) when max in [nil, 0], do: 0
  defp relative(p95, max), do: max(round(p95 / max * 100), 3)

  defp max_p95(calls),
    do: calls |> Enum.map(& &1.p95) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)

  defp error_kind(:no_answer), do: gettext("no answer")
  defp error_kind({:status, status}), do: to_string(status)
  defp error_kind(:command_failed), do: gettext("command failed")
  defp error_kind(:invalid_response), do: gettext("unexpected answer")
  defp error_kind(:exception), do: gettext("raised")
  defp error_kind(other), do: to_string(other)

  defp error_chip(%{kind: kind, server_id: nil}, _servers), do: error_kind(kind)

  defp error_chip(%{kind: kind, server_id: server_id}, servers),
    do: error_kind(kind) <> " · " <> server_short(servers, server_id)

  defp skip_reason(:conditions_not_met), do: gettext("Conditions did not match")
  defp skip_reason(:cooldown), do: gettext("On cooldown")
  defp skip_reason(:max_executions), do: gettext("Per-player cap in 24 h")
  defp skip_reason(:exempt), do: gettext("Exempt")
  defp skip_reason(reason), do: to_string(reason)

  defp skip_bar(:conditions_not_met), do: "bg-muted"
  defp skip_bar(:cooldown), do: "bg-warning"
  defp skip_bar(:max_executions), do: "bg-axis"
  defp skip_bar(:exempt), do: "bg-accent"
  defp skip_bar(_reason), do: "bg-base-content/40"

  defp most_common(%{rule_name: nil}), do: nil

  defp most_common(%{reason: :cooldown, rule_name: name, cooldown: seconds})
       when is_integer(seconds) and seconds > 0,
       do: gettext("most common: %{rule}, %{cooldown}", rule: name, cooldown: span(seconds))

  defp most_common(%{rule_name: name}), do: gettext("most common: %{rule}", rule: name)

  defp span(seconds) when seconds < 60, do: gettext("%{count} s", count: seconds)
  defp span(seconds) when seconds < 3_600, do: gettext("%{count} min", count: div(seconds, 60))
  defp span(seconds), do: gettext("%{count} h", count: div(seconds, 3_600))

  defp down?(%{segments: segments}), do: match?([%{state: :down} | _], Enum.reverse(segments))

  defp segment_class(:up), do: "bg-primary/80"
  defp segment_class(:blip), do: "bg-warning"
  defp segment_class(:down), do: "metrics-hatch"
  defp segment_class(_unknown), do: "bg-secondary"

  # Seconds, with a floor so a short drop stays visible on an hour's bar.
  defp segment_grow(%{state: :blip, ms: ms}), do: max(div(ms, 1000), 40)
  defp segment_grow(%{ms: ms}), do: max(div(ms, 1000), 1)

  defp axis(now, zone) do
    labels = for minutes <- [60, 45, 30, 15], do: hhmm(DateTime.add(now, -minutes * 60), zone)
    labels ++ [gettext("now")]
  end

  defp stream_detail(server, info, now_ms) do
    target = ws_target(server.base_url)
    reason = info && info.reason

    retry =
      case info && info.next_at do
        nil ->
          nil

        at when at > now_ms ->
          gettext("next attempt in %{seconds} s", seconds: div(at - now_ms + 999, 1000))

        _past ->
          gettext("retrying now")
      end

    Enum.join(Enum.reject([target, reason, retry], &is_nil/1), " · ")
  end

  defp ws_target(base_url) do
    uri = base_url |> to_string() |> String.trim() |> String.trim_trailing("/") |> URI.parse()
    scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
    "#{scheme} #{String.trim_trailing(uri.path || "", "/")}/ws/logs"
  end

  defp events_split(events, streams, servers) do
    down =
      for %{server: server, timeline: timeline} <- streams, down?(timeline), into: %{} do
        {server.id, timeline.down_since}
      end

    ids = Enum.uniq(events.seen_servers ++ Map.keys(down))

    ids
    |> Enum.map(fn id ->
      %{
        name: server_short(servers, id),
        count: Map.get(events.by_server, id, 0),
        down?: Map.has_key?(down, id),
        since: Map.get(down, id)
      }
    end)
    |> Enum.sort_by(&{&1.down?, -&1.count})
  end

  defp bar_height(_count, 0), do: 2
  defp bar_height(count, max), do: max(round(count / max * 100), 2)

  # ── Render ─────────────────────────────────────────────────────────────────

  attr :tone, :string, required: true
  slot :inner_block, required: true

  defp stream_chip(assigns) do
    ~H"""
    <span class={[
      "flex h-6 shrink-0 items-center gap-[5px] whitespace-nowrap rounded-full px-[9px] text-[0.6875rem] font-semibold",
      case @tone do
        "live" -> "bg-primary/12 text-primary"
        "error" -> "bg-error/14 text-error"
        "warning" -> "bg-warning/13 text-warning"
        _neutral -> "bg-secondary text-subtle"
      end
    ]}>
      <span class="size-1.5 rounded-full bg-current" aria-hidden="true"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :bar_max,
        assigns.events.per_minute |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)
      )
      |> assign(:split, events_split(assigns.events, assigns.log_streams, assigns.servers))
      |> assign(:p95_max, max_p95(assigns.calls))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Engine metrics")}
      crumb={crumb(@started_at, @now, @zone)}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      tabs={false}
      global_search={false}
      bell={false}
      scope={false}
    >
      <:actions>
        <span
          id="metrics-refresh"
          role="status"
          class="hidden h-12 items-center gap-2.5 rounded-full border border-base-300 bg-base-100 pl-[1.125rem] pr-2 text-[0.8125rem] text-subtle sm:flex"
        >
          <span
            class={[
              "size-2 shrink-0 rounded-full",
              if(@paused?, do: "bg-muted", else: "bg-primary ring-4 ring-primary/15")
            ]}
            aria-hidden="true"
          ></span>
          <span class={[
            "font-semibold",
            if(@paused?, do: "text-subtle", else: "text-primary")
          ]}>
            {if @paused?, do: gettext("Paused"), else: gettext("Refreshes every 2 s")}
          </span>
          <span class="hidden font-mono text-xs text-muted md:inline">{hhmmss(@now, @zone)}</span>
          <button
            type="button"
            id="metrics-pause"
            phx-click="toggle_refresh"
            aria-label={
              if @paused?, do: gettext("Resume refreshing"), else: gettext("Pause refreshing")
            }
            class="flex size-[2.125rem] cursor-pointer items-center justify-center rounded-full bg-secondary transition-colors hover:bg-base-300"
          >
            <.icon
              name={if @paused?, do: "hero-play-solid", else: "hero-pause-solid"}
              class="size-3.5"
            />
          </button>
        </span>
        <button
          type="button"
          id="metrics-reset"
          phx-click="reset"
          data-confirm={gettext("Clear every counter?")}
          aria-label={gettext("Reset counters")}
          class="flex h-12 cursor-pointer items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3.5 text-sm transition-colors hover:bg-secondary sm:pl-4 sm:pr-5"
        >
          <.icon name="hero-arrow-path" class="size-[1.125rem] -scale-x-100" />
          <span class="hidden sm:inline">{gettext("Reset counters")}</span>
        </button>
      </:actions>

      <div id="metrics-kpis" class="grid gap-4 md:grid-cols-3 xl:gap-5">
        <section
          id="metrics-events"
          aria-label={gettext("Events received per minute")}
          class="flex min-w-0 flex-col gap-2 rounded-[1.5rem] bg-base-100 px-[1.375rem] py-[1.125rem] md:h-44"
        >
          <div class="flex items-baseline justify-between gap-2">
            <span class="text-[0.8125rem] text-subtle">{gettext("Events received / min")}</span>
            <span
              :if={@events.change}
              class={["text-xs", if(@events.change >= 0, do: "text-primary", else: "text-warning")]}
            >
              {change_label(@events.change)}
            </span>
          </div>
          <strong class="font-display text-[2.375rem] font-semibold leading-none tabular-nums">
            {int(@events.last_minute)}
          </strong>
          <div
            class="grid min-h-10 flex-1 items-end gap-[3px]"
            style="grid-template-columns: repeat(30, minmax(0, 1fr))"
            aria-hidden="true"
          >
            <span
              :for={{bar, index} <- Enum.with_index(@events.per_minute)}
              class={[
                "rounded-[2px]",
                cond do
                  index == length(@events.per_minute) - 1 -> "bg-primary"
                  bar.drop? -> "bg-warning"
                  true -> "bg-line-strong"
                end
              ]}
              style={"height: #{bar_height(bar.count, @bar_max)}%"}
            ></span>
          </div>
          <p class="truncate text-xs text-muted">
            <span :if={@split == []}>{gettext("No server sent events in the last hour.")}</span>
            <span :for={{item, index} <- Enum.with_index(@split)}>
              {if index > 0, do: " · "}{item.name}
              <span :if={not item.down?} class="font-mono text-base-content">{int(item.count)}</span>
              <span :if={item.down? and item.since} class="font-mono text-error">
                {gettext("0 since %{time}", time: hhmm(item.since, @zone))}
              </span>
              <span :if={item.down? and is_nil(item.since)} class="font-mono text-error">0</span>
            </span>
          </p>
        </section>

        <section
          id="metrics-rules"
          aria-label={gettext("Rules fired and skipped")}
          class="flex min-w-0 flex-col gap-2.5 rounded-[1.5rem] bg-base-100 px-[1.375rem] py-[1.125rem] md:h-44"
        >
          <div class="flex items-baseline justify-between gap-2">
            <span class="text-[0.8125rem] text-subtle">{gettext("Rules in the last hour")}</span>
            <span class="text-xs text-muted">
              {gettext("%{count} evaluations", count: int(@rules.fired + @rules.skipped))}
            </span>
          </div>
          <div class="flex items-baseline gap-[1.375rem]">
            <span class="flex flex-col">
              <strong class="font-display text-[2.375rem] font-semibold leading-none text-primary tabular-nums">
                {int(@rules.fired)}
              </strong>
              <span class="mt-1 text-xs text-subtle">{gettext("fired")}</span>
            </span>
            <span class="font-display text-[1.375rem] text-muted">{gettext("vs")}</span>
            <span class="flex flex-col">
              <strong class="font-display text-[2.375rem] font-semibold leading-none tabular-nums">
                {int(@rules.skipped)}
              </strong>
              <span class="mt-1 text-xs text-subtle">{gettext("skipped")}</span>
            </span>
          </div>
          <span class="flex-1"></span>
          <div class="flex h-2.5 gap-[3px]" aria-hidden="true">
            <span
              :if={@rules.fired > 0}
              class="rounded bg-primary"
              style={"flex-grow: #{@rules.fired}"}
            ></span>
            <span
              class="rounded bg-line-strong"
              style={"flex-grow: #{max(@rules.skipped, if(@rules.fired == 0, do: 1, else: 0))}"}
            ></span>
          </div>
          <span class="truncate text-xs text-muted">
            {gettext(
              "%{percent}% of evaluations became an action · %{simulated} of them in simulation",
              percent: action_share(@rules),
              simulated: int(@rules.simulated)
            )}
          </span>
        </section>

        <section
          id="metrics-latency"
          aria-label={gettext("Time from event to action")}
          class="flex min-w-0 flex-col gap-2.5 rounded-[1.5rem] bg-base-100 px-[1.375rem] py-[1.125rem] md:h-44"
        >
          <div class="flex items-baseline justify-between gap-2">
            <span class="text-[0.8125rem] text-subtle">{gettext("From event to action")}</span>
            <span :if={@queue == 0} id="metrics-queue" class="text-xs text-primary">
              {gettext("queue empty")}
            </span>
            <span :if={@queue && @queue > 0} id="metrics-queue" class="text-xs text-warning">
              {ngettext("%{count} waiting", "%{count} waiting", @queue)}
            </span>
          </div>
          <div class="grid grid-cols-3 gap-2.5">
            <span
              :for={
                {label, value} <- [
                  {"p50", @latency.p50},
                  {"p95", @latency.p95},
                  {"p99", @latency.p99}
                ]
              }
              class="flex flex-col"
            >
              <span class="text-xs text-muted">{label}</span>
              <strong class={[
                "font-display text-[1.875rem] font-semibold leading-[1.1] tabular-nums",
                label == "p99" && latency_class(value) && "text-warning"
              ]}>
                {elem(duration_parts(value), 0)}<span
                  :if={elem(duration_parts(value), 1)}
                  class="text-[0.9375rem] font-normal text-muted"
                >{" " <> elem(duration_parts(value), 1)}</span>
              </strong>
            </span>
          </div>
          <span class="flex-1"></span>
          <div class="relative h-2.5 rounded bg-secondary" aria-hidden="true">
            <span
              :for={{left, width, class} <- latency_segments(@latency)}
              :if={width > 0}
              class={["absolute inset-y-0 rounded", class]}
              style={"left: #{left}%; width: #{width}%"}
            ></span>
          </div>
          <span class="truncate text-xs text-muted">
            <%= cond do %>
              <% @latency.count == 0 -> %>
                {gettext("No rule fired in the last hour.")}
              <% @latency.p99_cause && @latency.p99_cause.endpoint -> %>
                {gettext("p99 driven by")}
                <span class="font-mono text-base-content">{@latency.p99_cause.endpoint}</span>
                {trigger_context(@latency.p99_cause.trigger)}
              <% @latency.p99_cause -> %>
                {gettext("p99 driven by the engine itself")}
                {trigger_context(@latency.p99_cause.trigger)}
              <% true -> %>
                {gettext("From a rule firing to its actions finishing.")}
            <% end %>
          </span>
        </section>
      </div>

      <div class="grid items-stretch gap-4 xl:grid-cols-[minmax(0,1fr)_29.375rem] xl:gap-5">
        <section
          id="metrics-crcon"
          aria-label={gettext("CRCON calls")}
          class="flex min-w-0 flex-col overflow-hidden rounded-[1.75rem] bg-base-100 px-4 py-5 sm:px-6"
        >
          <div class="mb-3 flex flex-wrap items-center gap-3">
            <div class="flex min-w-fit flex-1 flex-col gap-0.5">
              <h2 class="font-display text-[1.25rem] font-semibold leading-[1.2]">
                {gettext("CRCON calls")}
              </h2>
              <span class="text-xs text-muted">
                {gettext("by endpoint · last hour · %{count} calls", count: int(@call_total))}
              </span>
            </div>
            <div
              :if={@crcon_servers != []}
              id="metrics-crcon-servers"
              role="tablist"
              aria-label={gettext("Server")}
              class="flex max-w-full gap-1 overflow-x-auto rounded-full bg-secondary p-1"
            >
              <button
                :for={
                  {id, label} <-
                    [{"all", gettext("All calls")}] ++
                      Enum.map(@crcon_servers, &{to_string(&1.id), short_name(&1)})
                }
                type="button"
                role="tab"
                id={"metrics-crcon-server-#{id}"}
                aria-selected={to_string(to_string(@crcon_server) == id)}
                phx-click="crcon_server"
                phx-value-id={id}
                class={[
                  "h-8 shrink-0 cursor-pointer whitespace-nowrap rounded-full px-3.5 text-xs transition-colors",
                  if(to_string(@crcon_server) == id,
                    do: "bg-inverse font-semibold text-on-inverse",
                    else: "text-subtle hover:text-base-content"
                  )
                ]}
              >
                {label}
              </button>
            </div>
          </div>

          <div
            class="metrics-calls-grid border-b border-line-soft px-2.5 py-2 text-xs text-muted"
            aria-hidden="true"
          >
            <span>{gettext("Endpoint")}</span>
            <span class="text-right">{gettext("Calls")}</span>
            <span class="max-md:hidden">{gettext("Errors")}</span>
            <span class="text-right max-md:hidden">{gettext("Average time")}</span>
            <span class="text-right">p95</span>
            <span class="max-md:hidden">{gettext("Relative p95")}</span>
          </div>

          <p :if={@calls == []} class="py-6 text-center text-sm text-muted">
            {gettext("No CRCON calls in the last hour.")}
          </p>

          <ul id="metrics-crcon-rows" class="flex flex-col">
            <li
              :for={row <- @calls}
              id={"metrics-call-#{row.endpoint}"}
              class={[
                "metrics-calls-grid border-b border-line-soft px-2.5 py-2.5 text-[0.8125rem] leading-[1.25] last:border-0",
                row.errors > 0 && "bg-error/5"
              ]}
            >
              <span class="truncate font-mono text-[0.78125rem]">{row.endpoint}</span>
              <span class="text-right font-mono">{int(row.calls)}</span>
              <span class={[
                "flex min-w-0 items-center gap-2",
                if(row.errors > 0, do: "max-md:order-last max-md:col-span-3", else: "max-md:hidden")
              ]}>
                <span :if={row.errors == 0} class="text-muted">0</span>
                <span :if={row.errors > 0} class="font-mono font-medium text-error">
                  {int(row.errors)}
                </span>
                <span
                  :if={row.error_breakdown != []}
                  class="truncate whitespace-nowrap rounded-full bg-error/14 px-2 py-0.5 text-[0.6875rem] font-semibold text-error"
                >
                  {error_chip(hd(row.error_breakdown), @servers)}
                </span>
              </span>
              <span class="text-right font-mono text-subtle max-md:hidden">{ms_label(row.average)}</span>
              <span class={["text-right font-mono", latency_class(row.p95)]}>{ms_label(row.p95)}</span>
              <span class="flex h-1.5 rounded-[3px] bg-secondary max-md:hidden">
                <span
                  class={[
                    "rounded-[3px]",
                    if(row.errors > 0 and (row.p95 || 0) >= 3_000,
                      do: "bg-error",
                      else: latency_bar(row.p95)
                    )
                  ]}
                  style={"width: #{relative(row.p95, @p95_max)}%"}
                ></span>
              </span>
            </li>
          </ul>

          <span class="flex-1"></span>
          <div
            :if={@insight}
            id="metrics-insight"
            class="mt-4 flex flex-wrap items-center gap-2.5 rounded-2xl bg-secondary px-3.5 py-3 text-[0.8125rem] text-subtle"
          >
            <.icon name="hero-exclamation-triangle" class="size-[1.125rem] shrink-0 text-warning" />
            <span class="min-w-0 flex-1">
              <%= if @insight.permission do %>
                {gettext("The 403s of")}
                <span class="font-mono text-base-content">{@insight.endpoint}</span>
                {gettext("come from the key of %{server} without",
                  server: short_name(@insight.server)
                )}
                <span class="font-mono text-base-content">{@insight.permission}</span>.
              <% else %>
                {gettext("The 403s of")}
                <span class="font-mono text-base-content">{@insight.endpoint}</span>
                {gettext("come from the key of %{server}, which CRCON refuses for it.",
                  server: short_name(@insight.server)
                )}
              <% end %>
            </span>
            <.link
              :if={@insight.server}
              navigate={~p"/executions?#{[status: "failed", server_id: @insight.server.id]}"}
              class="whitespace-nowrap text-[0.8125rem] text-primary hover:underline"
            >
              {gettext("See in history")}
            </.link>
          </div>
        </section>

        <div class="grid min-w-0 items-start gap-4 md:grid-cols-2 xl:flex xl:flex-col xl:items-stretch xl:gap-5">
          <section
            id="metrics-skipped"
            aria-label={gettext("Why rules were skipped")}
            class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
          >
            <div class="flex items-baseline gap-2">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold leading-[1.2]">
                {gettext("Why they were skipped")}
              </h2>
              <span class="text-xs text-muted">
                {gettext("%{count} in the last hour", count: int(@rules.skipped))}
              </span>
            </div>

            <p :if={@skips == []} class="text-sm text-muted">
              {gettext("No rule was skipped in the last hour.")}
            </p>

            <div
              :for={skip <- @skips}
              id={"metrics-skip-#{skip.reason}"}
              class="flex flex-col gap-1"
            >
              <div class="flex justify-between gap-2 text-[0.8125rem]">
                <span>{skip_reason(skip.reason)}</span>
                <span class="font-mono">
                  {int(skip.count)} <span class="text-muted">{share_label(skip.share)}</span>
                </span>
              </div>
              <span class="flex h-2.5 rounded bg-secondary">
                <span
                  class={["min-w-1.5 rounded", skip_bar(skip.reason)]}
                  style={"width: #{skip.share}%"}
                ></span>
              </span>
              <span :if={most_common(skip)} class="truncate text-xs text-muted">
                {most_common(skip)}
              </span>
            </div>
          </section>

          <section
            id="metrics-stream"
            aria-label={gettext("Log streaming")}
            class="flex flex-1 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5"
          >
            <div class="flex items-baseline gap-2">
              <h2 class="flex-1 font-display text-[1.25rem] font-semibold leading-[1.2]">
                {gettext("Log streaming")}
              </h2>
              <span class="text-xs text-muted">{gettext("reconnects · last hour")}</span>
            </div>

            <p :if={@log_streams == []} class="text-sm text-muted">
              {gettext("No server streams its logs to this app.")}
            </p>

            <div
              :for={%{server: server, timeline: timeline} <- @log_streams}
              id={"metrics-stream-#{server.id}"}
              class={[
                "flex flex-col gap-1.5",
                down?(timeline) && "-mx-3 rounded-[1.125rem] border border-error/28 bg-error/6 p-3"
              ]}
            >
              <div class="flex items-center gap-2 text-sm">
                <strong class="min-w-0 flex-1 truncate font-semibold">{server.name}</strong>
                <span
                  :if={down?(timeline)}
                  class="whitespace-nowrap font-mono text-xs text-error"
                >
                  {ngettext("%{count} attempt", "%{count} attempts", timeline.attempts)}
                </span>
                <span
                  :if={not down?(timeline)}
                  class={[
                    "whitespace-nowrap font-mono text-xs",
                    if(timeline.reconnects > 0, do: "text-warning", else: "text-muted")
                  ]}
                >
                  {ngettext("%{count} reconnect", "%{count} reconnects", timeline.reconnects)}
                </span>
                <.stream_chip :if={down?(timeline)} tone="error">
                  {if timeline.down_since,
                    do: gettext("down since %{time}", time: hhmm(timeline.down_since, @zone)),
                    else: gettext("down")}
                </.stream_chip>
                <.stream_chip :if={not down?(timeline) and timeline.status == :connected} tone="live">
                  {gettext("connected")}
                </.stream_chip>
                <.stream_chip
                  :if={not down?(timeline) and timeline.status in [:connecting, :error]}
                  tone="warning"
                >
                  {gettext("connecting")}
                </.stream_chip>
                <.stream_chip :if={is_nil(timeline.status)} tone="neutral">
                  {gettext("no data")}
                </.stream_chip>
              </div>
              <div class="flex h-3 gap-0.5 overflow-hidden rounded" aria-hidden="true">
                <span
                  :for={segment <- timeline.segments}
                  class={segment_class(segment.state)}
                  style={"flex-grow: #{segment_grow(segment)}"}
                ></span>
              </div>
              <span
                :if={down?(timeline)}
                class="truncate font-mono text-[0.71875rem] text-subtle"
              >
                {stream_detail(server, @stream_info[server.id], @now_ms)}
              </span>
            </div>

            <div
              :if={@log_streams != []}
              class="flex justify-between font-mono text-[0.6875rem] text-muted"
              aria-hidden="true"
            >
              <span :for={label <- axis(@now, @zone)}>{label}</span>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
