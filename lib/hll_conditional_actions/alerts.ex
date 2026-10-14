defmodule HllConditionalActions.Alerts do
  @moduledoc """
  Tells the people running the install, on Discord, when the app itself is
  in trouble - the things that otherwise only show up to someone reading
  the logs over SSH:

    * a server whose CRCON stream has been down for five minutes, and when
      it is back
    * errors (HTTP 500, a page that crashed) and pages that took more than
      five seconds, gathered into one message at most every ten minutes

  It is an operator setting, not a per-server one: `ALERT_WEBHOOK_URL` in
  `.env` names the Discord webhook, and without it this process is not
  started at all. Messages are written in `DEFAULT_LOCALE`.
  """

  use GenServer
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  require Logger

  alias HllConditionalActions.Crcon.LogStream
  alias HllConditionalActions.Discord.Client
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  @check_ms :timer.seconds(60)
  @stream_grace_ms :timer.minutes(5)
  @digest_every_ms :timer.minutes(10)
  @slow_ms 5_000

  @telemetry_id "hll-conditional-actions-alerts"

  @doc """
  Starts the alerter. Options: `:url` (the webhook, required), and for
  tests `:stream_grace_ms`, `:digest_every_ms` and `:check_ms`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The webhook alerts go to, when the operator set one."
  @spec webhook_url() :: String.t() | nil
  def webhook_url do
    case Application.get_env(:hll_conditional_actions, :alert_webhook_url) do
      url when is_binary(url) and url != "" -> url
      _unset -> nil
    end
  end

  @doc "Runs the periodic check now (tests)."
  @spec check(GenServer.server()) :: :ok
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  # ── Telemetry ──────────────────────────────────────────────────────────────

  @doc false
  def handle_telemetry([:phoenix, :endpoint, :stop], %{duration: duration}, %{conn: conn}, pid) do
    ms = System.convert_time_unit(duration, :native, :millisecond)
    path = conn.request_path

    # LiveView's own transports hold requests open on purpose.
    unless String.starts_with?(path, ["/live", "/socket"]) do
      cond do
        conn.status >= 500 -> send(pid, {:problem, :error, path, ms})
        ms >= @slow_ms -> send(pid, {:problem, :slow, path, ms})
        true -> :ok
      end
    end
  end

  def handle_telemetry([:phoenix, :live_view, _callback, :exception], _measures, meta, pid) do
    view = meta |> Map.get(:socket, %{}) |> Map.get(:view)
    send(pid, {:problem, :error, inspect(view), nil})
  end

  def handle_telemetry(_event, _measures, _meta, _pid), do: :ok

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    LogStream.subscribe_status()

    :telemetry.attach_many(
      {@telemetry_id, self()},
      [
        [:phoenix, :endpoint, :stop],
        [:phoenix, :live_view, :mount, :exception],
        [:phoenix, :live_view, :handle_params, :exception],
        [:phoenix, :live_view, :handle_event, :exception]
      ],
      &__MODULE__.handle_telemetry/4,
      self()
    )

    check_ms = Keyword.get(opts, :check_ms, @check_ms)
    if check_ms, do: :timer.send_interval(check_ms, :check)

    {:ok,
     %{
       url: Keyword.fetch!(opts, :url),
       stream_grace_ms: Keyword.get(opts, :stream_grace_ms, @stream_grace_ms),
       digest_every_ms: Keyword.get(opts, :digest_every_ms, @digest_every_ms),
       down: %{},
       problems: [],
       digest_sent_at: nil
     }}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach({@telemetry_id, self()})
    :ok
  end

  @impl GenServer
  def handle_call(:check, _from, state), do: {:reply, :ok, run_check(state)}

  @impl GenServer
  def handle_info(:check, state), do: {:noreply, run_check(state)}

  def handle_info({:crcon_stream_status, server_id, :connected}, state) do
    {gone, down} = Map.pop(state.down, server_id)

    if gone && gone.alerted?, do: post(state, back_text(server_id, gone))

    {:noreply, %{state | down: down}}
  end

  # Stopped on purpose (the server was disabled or deleted): nothing to say.
  def handle_info({:crcon_stream_status, server_id, :disconnected}, state) do
    {:noreply, %{state | down: Map.delete(state.down, server_id)}}
  end

  # Down or still trying: the clock starts at the first sign and keeps
  # running while the stream goes through its retries.
  def handle_info({:crcon_stream_status, server_id, status}, state) do
    reason =
      case status do
        {:error, reason} -> reason
        _connecting -> nil
      end

    down =
      Map.update(
        state.down,
        server_id,
        %{since: now(), reason: reason, alerted?: false},
        &%{&1 | reason: reason || &1.reason}
      )

    {:noreply, %{state | down: down}}
  end

  def handle_info({:problem, kind, where, ms}, state) do
    {:noreply, %{state | problems: [{kind, where, ms} | Enum.take(state.problems, 199)]}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Checking ───────────────────────────────────────────────────────────────

  defp run_check(state) do
    state
    |> alert_streams()
    |> send_digest()
  end

  defp alert_streams(state) do
    now = now()

    down =
      Map.new(state.down, fn {server_id, entry} ->
        if not entry.alerted? and now - entry.since >= state.stream_grace_ms and
             enabled?(server_id) do
          post(state, down_text(server_id, entry))
          {server_id, %{entry | alerted?: true}}
        else
          {server_id, entry}
        end
      end)

    %{state | down: down}
  end

  defp send_digest(%{problems: []} = state), do: state

  defp send_digest(state) do
    now = now()

    if is_nil(state.digest_sent_at) or now - state.digest_sent_at >= state.digest_every_ms do
      post(state, digest_text(state.problems))
      %{state | problems: [], digest_sent_at: now}
    else
      state
    end
  end

  defp enabled?(server_id) do
    match?({:ok, %Server{enabled: true}}, Servers.fetch_server(server_id))
  end

  # ── Messages ───────────────────────────────────────────────────────────────

  defp down_text(server_id, entry) do
    in_default_locale(fn ->
      text =
        gettext(
          "⚠️ **%{server}**: no events from CRCON for %{minutes} min. The rules of this server are blind until it is back.",
          server: server_name(server_id),
          minutes: minutes(entry.since)
        )

      if entry.reason, do: text <> "\n> " <> String.slice(entry.reason, 0, 300), else: text
    end)
  end

  defp back_text(server_id, entry) do
    in_default_locale(fn ->
      gettext("✅ **%{server}**: events from CRCON are back after %{minutes} min.",
        server: server_name(server_id),
        minutes: minutes(entry.since)
      )
    end)
  end

  defp digest_text(problems) do
    {errors, slow} = Enum.split_with(problems, fn {kind, _where, _ms} -> kind == :error end)

    in_default_locale(fn ->
      [
        errors != [] &&
          ngettext(
            "🛑 1 error in the app since the last report. Last one: `%{where}`.",
            "🛑 %{count} errors in the app since the last report. Last one: `%{where}`.",
            length(errors),
            where: errors |> hd() |> elem(1)
          ),
        slow != [] &&
          ngettext(
            "🐢 1 page took more than 5 s (%{seconds} s): `%{where}`.",
            "🐢 %{count} pages took more than 5 s, the slowest %{seconds} s: `%{where}`.",
            length(slow),
            seconds: slow |> Enum.map(&elem(&1, 2)) |> Enum.max() |> div(1000),
            where: slow |> Enum.max_by(&elem(&1, 2)) |> elem(1)
          )
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")
    end)
  end

  defp server_name(server_id) do
    case Servers.fetch_server(server_id) do
      {:ok, server} -> server.name
      _gone -> "##{server_id}"
    end
  end

  defp minutes(since), do: max(div(now() - since, 60_000), 1)

  defp post(state, text) do
    payload = %{"content" => text, "allowed_mentions" => %{"parse" => []}}

    Task.start(fn ->
      case Client.post(state.url, payload) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        other ->
          Logger.warning("[alerts] could not post to Discord: #{inspect(other)}")
      end
    end)

    :ok
  end

  defp in_default_locale(fun) do
    Gettext.with_locale(
      HllConditionalActionsWeb.Gettext,
      Application.get_env(:hll_conditional_actions, :default_locale, "en"),
      fun
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end
