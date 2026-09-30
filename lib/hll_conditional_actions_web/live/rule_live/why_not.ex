defmodule HllConditionalActionsWeb.RuleLive.WhyNot do
  @moduledoc """
  "Why didn't it fire?" on the rule page.

  Pick a player and a window, and every saved event of the rule's trigger
  for that player is walked through the engine's checks
  (`HllConditionalActions.Engine.Diagnosis`): the step the rule stopped at -
  switched off, paused, exempt, cooldown, cap, or the condition that failed
  with the value read against the value expected. Limits are replayed as
  they stood when the event arrived. When the rule did fire, the run is
  linked instead. The left column also says what the engine read.
  """

  use HllConditionalActionsWeb, :live_component

  import HllConditionalActionsWeb.DiagnosisComponents
  import HllConditionalActionsWeb.RuleComponents

  alias HllConditionalActions.Engine.Diagnosis
  alias HllConditionalActions.Engine.SavedEvents
  alias HllConditionalActions.Rules.Insights
  alias HllConditionalActionsWeb.EventEditor

  @limit 25

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    servers =
      Enum.filter(assigns.servers, fn server ->
        server.game == assigns.rule.game and
          (is_nil(assigns.rule.server_id) or server.id == assigns.rule.server_id)
      end)

    socket =
      socket
      |> assign(id: assigns.id, rule: assigns.rule, servers: servers)
      |> assign(zone: Map.get(assigns, :zone, "Etc/UTC"), version: Map.get(assigns, :version))
      |> assign_new(:query, fn ->
        %{"player" => "", "window" => "today", "from" => "", "to" => ""}
      end)
      |> assign_new(:player, fn -> nil end)
      |> assign_new(:results, fn -> nil end)
      |> assign_new(:selected, fn -> nil end)
      |> assign_new(:players, fn -> SavedEvents.players(Enum.map(servers, & &1.id)) end)

    # A player named in the link ("why not for this player?") starts the
    # search on today, widening to the last week when today has nothing; a
    # new rule definition re-judges the events already shown.
    case assigns[:player] do
      player when is_binary(player) and player != "" and is_nil(socket.assigns.player) ->
        socket =
          socket
          |> assign(:player, player)
          |> update(:query, &Map.merge(&1, %{"player" => player, "window" => "today"}))
          |> search()

        {:ok, if(socket.assigns.results == [], do: search(widen(socket)), else: socket)}

      _other ->
        {:ok, if(socket.assigns.player, do: search(socket), else: socket)}
    end
  end

  defp widen(socket) do
    week_ago =
      DateTime.utc_now()
      |> DateTime.add(-7 * 86_400, :second)
      |> Calendar.strftime("%Y-%m-%dT%H:%M")

    update(socket, :query, &Map.merge(&1, %{"window" => "custom", "from" => week_ago}))
  end

  @impl Phoenix.LiveComponent
  def handle_event("search", %{"why" => query}, socket) do
    query = Map.merge(socket.assigns.query, query)
    player = String.trim(query["player"] || "")

    socket =
      socket
      |> assign(:query, query)
      |> assign(:selected, nil)
      |> assign(:player, if(player == "", do: nil, else: player))

    {:noreply, if(player == "", do: assign(socket, :results, nil), else: search(socket))}
  end

  def handle_event("window", %{"why" => query}, socket) do
    socket = assign(socket, :query, Map.merge(socket.assigns.query, query))
    {:noreply, if(socket.assigns.player, do: search(socket), else: socket)}
  end

  def handle_event("change_player", _params, socket) do
    {:noreply,
     socket
     |> assign(:player, nil)
     |> assign(:results, nil)
     |> assign(:selected, nil)
     |> update(:query, &Map.put(&1, "player", ""))}
  end

  def handle_event("pick", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, id)}
  end

  defp search(socket) do
    {from, to} = window(socket.assigns.query, socket.assigns.zone)

    results =
      socket.assigns.servers
      |> Enum.map(& &1.id)
      |> SavedEvents.list(
        trigger: socket.assigns.rule.trigger_event,
        player: socket.assigns.player,
        from: from,
        to: to,
        limit: @limit
      )
      |> Enum.flat_map(&explain(&1, socket.assigns))

    assign(socket, :results, results)
  end

  defp window(%{"window" => "hour"}, _zone) do
    now = DateTime.utc_now()
    {DateTime.add(now, -3600, :second), now}
  end

  defp window(%{"window" => "custom"} = query, _zone),
    do: {parse_time(query["from"]), parse_time(query["to"])}

  defp window(_today, zone) do
    now = DateTime.utc_now()
    date = now |> local(zone) |> DateTime.to_date()

    from =
      case DateTime.new(date, ~T[00:00:00], zone) do
        {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
        _other -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      end

    {from, now}
  end

  # The event on the right: the one picked, or the most recent.
  defp chosen(nil, _selected), do: nil
  defp chosen([], _selected), do: nil
  defp chosen([first | _rest], nil), do: first

  defp chosen(results, selected),
    do: Enum.find(results, hd(results), &(to_string(&1.saved.id) == selected))

  defp explain(saved, %{rule: rule, servers: servers}) do
    case Enum.find(servers, &(&1.id == saved.server_id)) do
      nil ->
        []

      server ->
        sample = saved.sample
        context = EventEditor.to_context(sample, server)
        runs = Insights.runs_before(rule, sample.player_id, saved.occurred_at)

        [
          %{
            saved: saved,
            server: server,
            diagnosis: Diagnosis.diagnose(rule, context, at: saved.occurred_at),
            execution: Diagnosis.execution_for(rule, sample.player_id, saved.occurred_at),
            limits: %{
              last: runs |> List.last() |> then(&(&1 && &1.executed_at)),
              count: length(runs)
            }
          }
        ]
    end
  end

  # `datetime-local` posts "2026-09-26T21:30", read as UTC like the rest
  # of the stored times.
  defp parse_time(value) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _error -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp initials(nil), do: "?"

  defp initials(name) do
    name
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> case do
      [one] -> String.slice(one, 0, 2)
      [a, b | _rest] -> String.first(a) <> String.first(b)
      [] -> String.slice(name, 0, 2)
    end
    |> String.upcase()
  end

  defp player_info(results, player, players) do
    case results do
      [%{saved: %{sample: sample}} | _rest] ->
        %{
          name: sample.player_name || player,
          id: sample.player_id,
          vip?: get_in(sample, [Access.key(:player), "is_vip"]) in [true, "true"],
          team: get_in(sample, [Access.key(:player), "team"])
        }

      _none ->
        # No event kept for them: the name the saved events knew, if any.
        case List.keyfind(players, player, 0) do
          {id, name} -> %{name: name || id, id: id, vip?: false, team: nil}
          nil -> %{name: player, id: nil, vip?: false, team: nil}
        end
    end
  end

  defp window_line(query, zone) do
    case window(query, zone) do
      {%DateTime{} = from, to} ->
        local_from = local(from, zone)
        local_to = local(to || DateTime.utc_now(), zone)
        from_date = DateTime.to_date(local_from)
        to_date = DateTime.to_date(local_to)

        # One day reads "Tue, 29 Sep · 00:00 – 21:50"; a longer window names
        # both ends.
        if from_date == to_date do
          "#{weekday_short(from_date)}, #{day_month(from_date)} · " <>
            Calendar.strftime(local_from, "%H:%M") <>
            " – " <> Calendar.strftime(local_to, "%H:%M")
        else
          "#{day_month(from_date)} " <>
            Calendar.strftime(local_from, "%H:%M") <>
            " – #{day_month(to_date)} " <> Calendar.strftime(local_to, "%H:%M")
        end

      _open ->
        gettext("pick the start and the end")
    end
  end

  defp read_rows(result) do
    conditions =
      result.diagnosis.conditions
      |> Enum.reject(&(&1.field == :always_true))
      |> Enum.uniq_by(& &1.field)
      |> Enum.map(&{Labels.field(&1.field), read_value(&1.actual), nil})

    team =
      case get_in(result.saved.sample, [Access.key(:player), "team"]) do
        "allies" -> [{gettext("Team"), gettext("Allies"), "text-allies"}]
        "axis" -> [{gettext("Team"), gettext("Axis"), "text-axis"}]
        _other -> []
      end

    conditions ++ team
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assigns
      |> assign(:current, chosen(assigns.results, assigns.selected))
      |> assign(
        :info,
        assigns.player && player_info(assigns.results, assigns.player, assigns.players)
      )

    ~H"""
    <div id={@id} class="grid items-start gap-5 xl:grid-cols-[25rem_minmax(0,1fr)] xl:items-stretch">
      <section
        aria-label={gettext("Who and when")}
        class="flex min-w-0 flex-col gap-4 rounded-[1.75rem] bg-base-100 px-6 py-[1.375rem]"
      >
        <div class="flex flex-col gap-1">
          <h2 class="font-display text-xl font-semibold">{gettext("Who and when")}</h2>
          <p class="text-[0.8125rem] leading-snug text-muted">
            {gettext("Pick a player and a moment. The event's path through the rule is walked again.")}
          </p>
        </div>

        <div class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">{gettext("Player")}</span>
          <div
            :if={@info}
            id="why-not-player"
            class="flex items-center gap-3 rounded-2xl border border-base-300 bg-secondary px-3 py-2.5"
          >
            <span class={[
              "flex size-10 shrink-0 items-center justify-center rounded-xl text-[0.8125rem] font-bold",
              if(@info.team == "axis",
                do: "bg-axis/14 text-axis",
                else: "bg-allies/14 text-allies"
              )
            ]}>
              {initials(@info.name)}
            </span>
            <span class="flex min-w-0 flex-1 flex-col gap-0.5">
              <strong class="truncate text-[0.9375rem] font-semibold">{@info.name}</strong>
              <span :if={@info.id} class="truncate font-mono text-[0.6875rem] text-muted">
                {@info.id}
              </span>
            </span>
            <span
              :if={@info.vip?}
              class="rounded-full bg-warning/13 px-2 py-[3px] text-[0.6875rem] font-semibold text-warning"
            >
              VIP
            </span>
            <button
              type="button"
              phx-click="change_player"
              phx-target={@myself}
              class="h-8 cursor-pointer rounded-full border border-base-300 bg-base-100 px-3 text-xs transition-colors hover:bg-base-200"
            >
              {gettext("Change")}
            </button>
          </div>
          <form
            :if={is_nil(@info)}
            id="why-not-form"
            phx-submit="search"
            phx-target={@myself}
            class="flex gap-2"
          >
            <label class="flex h-11 min-w-0 flex-1 items-center gap-2 rounded-2xl border border-base-300 bg-secondary px-3.5 text-muted">
              <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
              <span class="sr-only">{gettext("Player (name or ID)")}</span>
              <input
                type="text"
                name="why[player]"
                value={@query["player"]}
                list="why-not-players"
                autocomplete="off"
                placeholder={gettext("Name or Steam ID")}
                class="w-full border-0 bg-transparent p-0 text-sm text-base-content placeholder:text-muted focus:ring-0"
              />
            </label>
            <datalist id="why-not-players">
              <option :for={{player_id, name} <- @players} value={player_id}>{name}</option>
            </datalist>
            <button
              type="submit"
              class="h-11 cursor-pointer rounded-full bg-primary px-4 text-sm font-semibold text-primary-content transition-opacity hover:opacity-90"
            >
              {gettext("Explain")}
            </button>
          </form>
        </div>

        <form
          id="why-not-window"
          phx-change="window"
          phx-target={@myself}
          class="flex flex-col gap-1.5"
        >
          <span class="text-xs text-muted">{gettext("Time window")}</span>
          <.pill_radios
            name="why[window]"
            value={@query["window"]}
            label={gettext("Time window")}
            options={[
              {"hour", gettext("Last hour")},
              {"today", gettext("Today")},
              {"custom", gettext("Pick")}
            ]}
          />
          <div :if={@query["window"] == "custom"} class="grid grid-cols-2 gap-2.5 pt-1">
            <label class="flex flex-col gap-1">
              <span class="text-xs text-muted">{gettext("From (UTC)")}</span>
              <input
                type="datetime-local"
                name="why[from]"
                value={@query["from"]}
                class="pc-text-input w-full"
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-xs text-muted">{gettext("To (UTC)")}</span>
              <input
                type="datetime-local"
                name="why[to]"
                value={@query["to"]}
                class="pc-text-input w-full"
              />
            </label>
          </div>
          <span class="font-mono text-xs text-muted">{window_line(@query, @zone)}</span>
        </form>

        <p
          :if={@results == []}
          class="rounded-2xl bg-secondary px-4 py-3 text-[0.8125rem] text-muted"
        >
          <span class="block font-semibold text-base-content">
            {gettext("No saved event for that player")}
          </span>
          {gettext(
            "Only the latest events of each trigger are kept, per server. Try a wider window, or check the player's ID."
          )}
        </p>

        <div :if={@results not in [nil, []]} class="flex flex-col gap-1.5">
          <span class="text-xs text-muted">
            {ngettext(
              "1 event of theirs this rule listens for",
              "%{count} events of theirs this rule listens for",
              length(@results)
            )}
          </span>
          <ul
            id="why-not-results"
            role="radiogroup"
            class="-mr-2 flex max-h-[22rem] flex-col gap-1.5 overflow-y-auto pr-2"
          >
            <li :for={result <- @results} id={"why-#{result.saved.id}"}>
              <button
                type="button"
                role="radio"
                phx-click="pick"
                phx-value-id={result.saved.id}
                phx-target={@myself}
                aria-checked={to_string(@current.saved.id == result.saved.id)}
                class={[
                  "grid w-full cursor-pointer grid-cols-[4.125rem_minmax(0,1fr)] items-center gap-2.5 rounded-[0.875rem] border px-3 py-2.5 text-left transition-colors",
                  if(@current.saved.id == result.saved.id,
                    do: "border-primary/50 bg-primary/8",
                    else: "border-base-300 bg-secondary hover:border-primary/30"
                  )
                ]}
              >
                <span class={[
                  "font-mono text-xs",
                  if(@current.saved.id == result.saved.id, do: "text-primary", else: "text-muted")
                ]}>
                  {clock(result.saved.occurred_at, @zone)}
                </span>
                <span class="flex min-w-0 flex-col gap-px">
                  <span class={[
                    "truncate text-sm",
                    @current.saved.id == result.saved.id && "font-semibold"
                  ]}>
                    {event_text(result.saved.sample, @rule.trigger_event)}
                  </span>
                  <span class={[
                    "truncate text-xs",
                    if(@current.saved.id == result.saved.id, do: "text-subtle", else: "text-muted")
                  ]}>
                    {result.server.name} · {if result.execution,
                      do: gettext("fired"),
                      else: gettext("did not fire")}
                  </span>
                </span>
              </button>
            </li>
          </ul>
        </div>

        <div
          :if={@current && read_rows(@current) != []}
          id="why-not-read"
          class="mt-auto flex flex-col gap-2 rounded-[1.125rem] bg-secondary px-4 py-3.5"
        >
          <span class="text-xs text-muted">
            {gettext("What the engine read at %{time}",
              time: clock(@current.saved.occurred_at, @zone)
            )}
          </span>
          <div
            :for={{label, value, tone} <- read_rows(@current)}
            class="flex items-baseline justify-between gap-3 text-[0.8125rem]"
          >
            <span class="text-subtle">{label}</span>
            <span class={[
              "text-right",
              if(tone, do: "text-xs font-semibold #{tone}", else: "font-mono text-xs")
            ]}>
              {value}
            </span>
          </div>
        </div>
      </section>

      <section
        :if={@current}
        id="why-not-path"
        aria-label={gettext("The path of the event")}
        class="flex min-w-0 flex-col gap-3.5 rounded-[1.75rem] bg-base-100 px-5 py-[1.375rem] sm:px-7"
      >
        <div class="flex flex-wrap items-start gap-4">
          <div class="flex min-w-0 flex-1 flex-col gap-1">
            <h2 class="font-display text-xl font-semibold">
              {gettext("The path of the event at")}
              <span class="font-mono text-lg">{clock(@current.saved.occurred_at, @zone)}</span>
            </h2>
            <p class="text-[0.8125rem] text-muted">
              {@current.saved.sample.player_name || gettext("The player")} {event_text(
                @current.saved.sample,
                @rule.trigger_event
              )} · {@current.server.name} · {gettext(
                "the rule checks in this order and stops at the first no"
              )}
            </p>
          </div>
          <.link
            navigate={
              ~p"/rules/simulate?#{[server_id: @current.server.id, trigger: @rule.trigger_event, event_id: @current.saved.id]}"
            }
            class="flex h-10 items-center rounded-full border border-base-300 bg-secondary px-4 text-[0.8125rem] transition-colors hover:bg-base-200"
          >
            {gettext("Open in the simulator")}
          </.link>
        </div>

        <.event_path
          id="why-not-steps"
          diagnosis={@current.diagnosis}
          rule={@rule}
          server={@current.server}
          sample={@current.saved.sample}
          execution={@current.execution}
          limits={@current.limits}
          version={@version}
          zone={@zone}
        />
      </section>

      <section
        :if={is_nil(@current)}
        class="hidden min-h-64 flex-col items-center justify-center gap-2 rounded-[1.75rem] border border-dashed border-base-300 p-8 text-center xl:flex"
      >
        <.icon name="hero-arrow-left" class="size-5 text-muted" />
        <p class="max-w-sm text-[0.8125rem] text-muted">
          {gettext("Pick a player and the path of each of their events through this rule shows here.")}
        </p>
      </section>
    </div>
    """
  end
end
