defmodule HllConditionalActionsWeb.MetricsLive do
  @moduledoc """
  What the engine is actually doing, read from
  `HllConditionalActions.Metrics`.

  Answers the questions you have when something looks wrong: are events
  arriving at all, are rules firing or being skipped, and is CRCON responding
  quickly. Counters are cumulative since the node started and reset with it —
  for history, attach a reporter to
  `HllConditionalActionsWeb.Telemetry.metrics/0`.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :view_executions}}

  alias HllConditionalActions.Metrics

  @refresh_ms 2_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok, socket |> assign(:page_title, gettext("Metrics")) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_event("reset", _params, socket) do
    :ok = Metrics.reset()

    {:noreply, socket |> put_flash(:info, gettext("Counters reset.")) |> load()}
  end

  defp load(socket) do
    metrics = Metrics.snapshot()

    socket
    |> assign(:metrics, metrics)
    |> assign(:empty?, Metrics.total_events() == 0)
  end

  # ── Formatting ─────────────────────────────────────────────────────────────

  defp total(entries), do: entries |> Enum.map(fn {_key, value} -> value end) |> Enum.sum()

  defp fired_total(metrics), do: total(metrics.rules.fired)

  defp skip_reason(:cooldown), do: gettext("Cooldown")
  defp skip_reason(:max_executions), do: gettext("Per-player cap")
  defp skip_reason(:conditions_not_met), do: gettext("Conditions did not hold")
  defp skip_reason(reason), do: to_string(reason)

  defp outcome_label(:ok), do: gettext("Succeeded")
  defp outcome_label(:command_failed), do: gettext("Command failed")
  defp outcome_label(:unauthorized), do: gettext("Rejected the key")
  defp outcome_label(:not_found), do: gettext("Endpoint missing")
  defp outcome_label(:transport_error), do: gettext("Could not reach CRCON")
  defp outcome_label(:invalid_response), do: gettext("Unexpected answer")
  defp outcome_label(:http_error), do: gettext("HTTP error")
  defp outcome_label(:exception), do: gettext("Raised")
  defp outcome_label(other), do: to_string(other)

  defp outcome_tone(:ok), do: "success"
  defp outcome_tone(_other), do: "error"

  # Anything slower than this from CRCON is worth a second look: the engine
  # blocks on these calls while evaluating.
  defp latency_class(average) when average < 250, do: "text-success"
  defp latency_class(average) when average < 1_000, do: "text-warning"
  defp latency_class(_average), do: "text-error"

  defp since(nil), do: gettext("unknown")

  defp since(started_at) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)

    cond do
      seconds < 60 -> gettext("%{count}s", count: seconds)
      seconds < 3_600 -> gettext("%{count}min", count: div(seconds, 60))
      true -> gettext("%{count}h", count: div(seconds, 3_600))
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      page_title={gettext("Metrics")}
      page_subtitle={gettext("What your rules have been doing")}
    >
      <:actions>
        <.button
          type="button"
          size="sm"
          variant="ghost"
          color="gray"
          icon="hero-arrow-path"
          phx-click="reset"
          data-confirm={gettext("Clear every counter?")}
          label={gettext("Reset")}
        />
      </:actions>

      <p class="flex items-center gap-1.5 text-sm text-muted">
        <.icon name="hero-clock" class="size-3.5 shrink-0" />
        {gettext("Counting for %{duration}. Cleared whenever the application restarts.",
          duration: since(@metrics.started_at)
        )}
      </p>

      <.empty_state
        :if={@empty?}
        icon="hero-chart-bar"
        title={gettext("Nothing measured yet")}
        description={
          gettext(
            "Numbers appear as soon as a server connects and events start arriving. If this stays empty, the log stream is probably not reaching this app."
          )
        }
      />

      <div :if={not @empty?} class="space-y-6">
        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat
            label={gettext("Rules fired")}
            value={fired_total(@metrics)}
            icon="hero-bolt"
          />
          <.stat
            label={gettext("Rules skipped")}
            value={total(@metrics.rules.skipped)}
            icon="hero-minus-circle"
          />
          <.stat
            label={gettext("Game events")}
            value={total(@metrics.log_stream.events)}
            icon="hero-signal"
          />
          <.stat
            label={gettext("CRCON calls")}
            value={total(@metrics.crcon.requests)}
            icon="hero-arrows-right-left"
          />
        </div>

        <div class="grid gap-4 lg:grid-cols-2">
          <.panel title={gettext("Rules that fired")} empty={@metrics.rules.fired == []}>
            <ul class="divide-y divide-base-300">
              <li
                :for={{status, count} <- @metrics.rules.fired}
                class="flex items-center justify-between py-2 text-sm"
              >
                <.tone_badge tone="neutral">{Labels.execution_status(status)}</.tone_badge>
                <span class="font-mono">{count}</span>
              </li>
            </ul>

            <div :if={@metrics.rules.duration} class="mt-3 rounded-box bg-base-200 p-3 text-sm">
              <p class="mb-1 font-medium">{gettext("Time from decision to actions finishing")}</p>
              <div class="flex gap-4 font-mono text-xs">
                <span>{gettext("avg")} {@metrics.rules.duration.average}ms</span>
                <span>{gettext("max")} {@metrics.rules.duration.max}ms</span>
                <span>{gettext("last")} {@metrics.rules.duration.last}ms</span>
              </div>
            </div>
          </.panel>

          <.panel title={gettext("Why rules were skipped")} empty={@metrics.rules.skipped == []}>
            <ul class="divide-y divide-base-300">
              <li
                :for={{reason, count} <- @metrics.rules.skipped}
                class="flex items-center justify-between py-2 text-sm"
              >
                <span>{skip_reason(reason)}</span>
                <span class="font-mono">{count}</span>
              </li>
            </ul>
            <p class="mt-2 text-xs text-muted">
              {gettext(
                "A trigger reached the rule but it did not run. Mostly conditions not holding, which is normal."
              )}
            </p>
          </.panel>

          <.panel title={gettext("Game events received")} empty={@metrics.log_stream.events == []}>
            <ul class="divide-y divide-base-300">
              <li
                :for={{type, count} <- @metrics.log_stream.events}
                class="flex items-center justify-between py-2 text-sm"
              >
                <span>{Labels.event_type(type)}</span>
                <span class="font-mono">{count}</span>
              </li>
            </ul>
          </.panel>

          <.panel
            title={gettext("Log stream connections")}
            empty={@metrics.log_stream.statuses == []}
          >
            <ul class="divide-y divide-base-300">
              <li
                :for={{status, count} <- @metrics.log_stream.statuses}
                class="flex items-center justify-between py-2 text-sm"
              >
                <span>{Labels.stream_status(status)}</span>
                <span class="font-mono">{count}</span>
              </li>
            </ul>
            <p class="mt-2 text-xs text-muted">
              {gettext("Repeated reconnects mean a server this app cannot hold a stream to.")}
            </p>
          </.panel>
        </div>

        <.panel
          title={gettext("CRCON round trip by endpoint")}
          empty={@metrics.crcon.duration_by_endpoint == []}
        >
          <table class="table-collapse app-table">
            <thead class="text-xs uppercase tracking-wide text-muted">
              <tr>
                <th>{gettext("Endpoint")}</th>
                <th class="text-right">{gettext("Calls")}</th>
                <th class="text-right">{gettext("Average")}</th>
                <th class="text-right">{gettext("Slowest")}</th>
                <th class="text-right">{gettext("Last")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :for={{endpoint, stats} <- @metrics.crcon.duration_by_endpoint}>
                <td data-cell="lead" class="break-all font-mono text-xs">{endpoint}</td>
                <td data-label={gettext("Calls")} class="text-right font-mono">{stats.count}</td>
                <td
                  data-label={gettext("Average")}
                  class={["text-right font-mono", latency_class(stats.average)]}
                >
                  {stats.average}ms
                </td>
                <td data-label={gettext("Slowest")} class="text-right font-mono">{stats.max}ms</td>
                <td data-label={gettext("Last")} class="text-right font-mono">{stats.last}ms</td>
              </tr>
            </tbody>
          </table>
        </.panel>

        <.panel title={gettext("CRCON call outcomes")} empty={@metrics.crcon.requests == []}>
          <table class="table-collapse app-table">
            <thead class="text-xs uppercase tracking-wide text-muted">
              <tr>
                <th>{gettext("Endpoint")}</th>
                <th>{gettext("Outcome")}</th>
                <th class="text-right">{gettext("Calls")}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :for={{{endpoint, outcome}, count} <- @metrics.crcon.requests}>
                <td data-cell="lead" class="break-all font-mono text-xs">{endpoint}</td>
                <td data-label={gettext("Outcome")}>
                  <.tone_badge tone={outcome_tone(outcome)}>
                    {outcome_label(outcome)}
                  </.tone_badge>
                </td>
                <td data-label={gettext("Calls")} class="text-right font-mono">{count}</td>
              </tr>
            </tbody>
          </table>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :empty, :boolean, default: false
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <.card title={@title}>
      <p :if={@empty} class="py-4 text-center text-sm text-muted">
        {gettext("Nothing recorded yet.")}
      </p>

      <div :if={not @empty}>{render_slot(@inner_block)}</div>
    </.card>
    """
  end
end
