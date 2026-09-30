defmodule HllConditionalActionsWeb.LiveComponents do
  @moduledoc """
  The pieces of the *Ao vivo* area: the server cockpit, the live feed and
  the leaderboard.

    * `live_hero/1` - the match as a scoreboard over the map's picture: map,
      mode and start, time left, the score in the teams' colours with the
      five sectors under it, and the head count of each side. `compact` is
      the slim strip the leaderboard opens with.
    * `live_panel/1` - the panel every block of the area sits on.
    * `match_views/1` - Feed · Placar · Squads, the views of a live match.
    * `feed_filters/1` - the chips over a feed (everything, kills, chat,
      only where a rule acted) and its pause button.
    * `feed_row/1` - one line of the live feed: time, what happened, who, in
      their team's colour, and the rule (or ticket) that acted on it.
    * `rank_card/1` - one leaderboard category: the podium, coloured by team.
    * `initials_tile/1` - a player's or squad's initials on their team's tint.

  Team names follow the server's game (`team_names/1`): *Allies* and *Axis*
  in Hell Let Loose, the *US* and the *NVA* in Vietnam.
  """

  use Phoenix.Component
  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import HllConditionalActionsWeb.Ui, only: [team_text: 1]
  import PetalComponents.Icon

  alias HllConditionalActions.LiveFeed
  alias HllConditionalActionsWeb.Labels
  alias HllConditionalActionsWeb.MapArt

  # ── Teams ──────────────────────────────────────────────────────────────────

  @doc """
  The short names of both teams in the server's game, keyed by CRCON's
  spelling: `%{"allies" => "Allies", "axis" => "Axis"}` for Hell Let Loose,
  `%{"allies" => "US", "axis" => "NVA"}` for Vietnam - CRCON keeps the
  `allies` / `axis` keys for Vietnam's factions.
  """
  @spec team_names(atom() | String.t() | nil) :: %{String.t() => String.t()}
  def team_names(game) when game in [:hllv, "hllv"],
    do: %{"allies" => gettext("US"), "axis" => gettext("NVA")}

  def team_names(_game), do: %{"allies" => gettext("Allies"), "axis" => gettext("Axis")}

  @doc """
  The names over the score of the hero: the short names, except Vietnam's
  South, which reads "Allies (US)".
  """
  @spec team_headings(atom() | String.t() | nil) :: %{String.t() => String.t()}
  def team_headings(game) when game in [:hllv, "hllv"],
    do: %{"allies" => gettext("Allies (US)"), "axis" => gettext("NVA")}

  def team_headings(game), do: team_names(game)

  @doc "CRCON's team spelling, lower case, or nil."
  @spec team_key(term()) :: String.t() | nil
  def team_key(team) when is_binary(team) do
    case String.downcase(team) do
      "allies" -> "allies"
      "axis" -> "axis"
      _other -> nil
    end
  end

  def team_key(team) when team in [:allies, :axis], do: Atom.to_string(team)
  def team_key(_team), do: nil

  # ── Panels ─────────────────────────────────────────────────────────────────

  @doc """
  The panel of the area: the page's surface, a display title, one link or
  figure on the right.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :title_id, :string, default: nil
  attr :class, :any, default: nil
  attr :wide, :boolean, default: false, doc: "the feed's roomier sides on a wide screen"
  attr :gap, :any, default: "gap-3", doc: "the space between the title and the blocks"
  attr :rest, :global
  slot :aside, doc: "what sits right of the title: a link, a count"
  slot :inner_block, required: true

  def live_panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "flex min-w-0 flex-col rounded-[1.5rem] bg-base-100 p-4 shadow-[0_1px_2px_rgb(22_23_15/0.05)] md:rounded-[1.75rem] md:px-5 md:py-4.5 xl:py-5 dark:shadow-none",
        if(@wide, do: "xl:px-6", else: "xl:px-5.5"),
        @gap,
        @class
      ]}
      {@rest}
    >
      <header :if={@title || @aside != []} class="flex items-baseline gap-3">
        <h2
          :if={@title}
          id={@title_id}
          class="min-w-0 flex-1 font-display text-lg font-semibold md:text-xl"
        >
          {@title}
        </h2>
        {render_slot(@aside)}
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "The link on the right of a panel title."
  attr :navigate, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def panel_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "shrink-0 text-[0.8125rem] text-primary transition-opacity hover:opacity-80",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  The views of a live match - the feed, the leaderboard and its squads - as
  one pill switch. `current` is the view being shown.
  """
  attr :id, :string, required: true
  attr :base, :string, required: true, doc: "the server's path, /servers/:id"
  attr :current, :atom, required: true, values: [:feed, :leaderboard, :squads]
  attr :feed?, :boolean, default: true, doc: "whether the feed can be opened"
  attr :stats?, :boolean, default: true, doc: "whether the leaderboard can be opened"
  attr :class, :any, default: nil

  def match_views(assigns) do
    ~H"""
    <nav
      id={@id}
      aria-label={gettext("Match views")}
      class={["flex shrink-0 gap-1 rounded-full p-1", @class]}
    >
      <.match_view :if={@feed?} path={@base} active={@current == :feed}>
        {gettext("Feed")}
      </.match_view>
      <.match_view
        :if={@stats?}
        path={@base <> "/leaderboard"}
        active={@current == :leaderboard}
      >
        {gettext("Scoreboard")}
      </.match_view>
      <.match_view
        :if={@stats?}
        path={@base <> "/leaderboard?view=squads"}
        active={@current == :squads}
      >
        {gettext("Squads")}
      </.match_view>
    </nav>
    """
  end

  attr :path, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  defp match_view(assigns) do
    ~H"""
    <.link
      navigate={@path}
      aria-current={@active && "page"}
      class={[
        "flex h-9 items-center rounded-full px-4 text-[0.8125rem] transition-colors",
        if(@active,
          do: "bg-base-content font-semibold text-base-100",
          else: "text-subtle hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── The live hero ──────────────────────────────────────────────────────────

  @doc """
  The live match over the picture of its map.

  The hero is always drawn on the dark scheme - it sits on a photo under a
  dark scrim - so the signal and the team colours keep their bright shades
  in the light theme too (see `assets/css/areas/live.css`). It has three
  shapes: the wide three columns from `xl`, a tablet one with the score
  beside the map and the head count under both, and the phone's, the score
  at the bottom of the picture.
  """
  attr :id, :string, required: true
  attr :server, :map, required: true
  attr :gamestate, :map, default: nil
  attr :roster, :map, default: nil
  attr :stream_status, :any, default: nil
  attr :started_at, :any, default: nil, doc: "when the match started, a DateTime"
  attr :max_players, :integer, default: nil, doc: "the server's player cap"
  attr :loading?, :boolean, default: false
  attr :error?, :boolean, default: false
  attr :compact, :boolean, default: false, doc: "the one line strip of the leaderboard"
  slot :action, doc: "a control on the right of the compact strip"

  def live_hero(assigns) do
    gs = assigns.gamestate || %{}
    allied_players = number(gs["num_allied_players"])
    axis_players = number(gs["num_axis_players"])

    assigns =
      assign(assigns,
        map: map_name(gs),
        mode: gs["game_mode"],
        allied: number(gs["allied_score"]),
        axis: number(gs["axis_score"]),
        allied_players: allied_players,
        axis_players: axis_players,
        players: allied_players + axis_players,
        time_left: time_left(gs["raw_time_remaining"]),
        queue: side_tile(gs["queue_count"], assigns.roster, assigns.server.game),
        vips: vip_count(assigns.roster),
        art: hero_art(gs, assigns.server),
        teams: team_names(assigns.server.game),
        headings: team_headings(assigns.server.game),
        started: started_label(assigns.started_at, assigns.server),
        ready?: not assigns.loading? and not assigns.error?
      )

    ~H"""
    <section
      id={@id}
      aria-label={gettext("Live match")}
      class={[
        "dark live-hero relative isolate shrink-0 overflow-hidden",
        if(@compact, do: "rounded-3xl", else: "rounded-[1.625rem] md:rounded-[1.75rem]")
      ]}
    >
      <img src={@art} alt="" class="absolute inset-0 -z-10 size-full object-cover" />
      <div
        class={[
          "absolute inset-0 -z-10",
          if(@compact, do: "live-hero-strip", else: "live-hero-scrim")
        ]}
        aria-hidden="true"
      >
      </div>

      <%= if @compact do %>
        <.hero_strip {assigns} />
      <% else %>
        <%!-- Wide: where and what · the score · who is playing. --%>
        <div class="hidden h-[18.75rem] grid-cols-[minmax(0,1fr)_minmax(0,1.25fr)_minmax(0,1fr)] gap-8 px-8.5 py-7.5 xl:grid">
          <div class="flex min-w-0 flex-col gap-2.5">
            <.live_pill stream_status={@stream_status} label={gettext("Live match")} />
            <h2 class="mt-2 truncate font-display text-6xl font-bold leading-[0.95] tracking-[-0.035em]">
              <.map_title map={@map} loading?={@loading?} error?={@error?} />
            </h2>
            <span :if={@ready?} class="truncate text-[0.9375rem] text-base-content/80">
              {mode_line(@mode, @started)}
            </span>
            <span class="grow"></span>
            <span class="flex items-center gap-2 text-[0.8125rem] text-base-content/80">
              <.icon name="hero-signal" class={["size-4", stream_text(@stream_status)]} />
              {stream_phrase(@stream_status)}
            </span>
          </div>

          <div :if={@ready?} class="flex flex-col items-center justify-center gap-3.5">
            <div class="flex items-center gap-7">
              <.score team="allies" label={@headings["allies"]} value={@allied} size="xl" />
              <span class="font-display text-[2.5rem] text-base-content/40" aria-hidden="true">
                :
              </span>
              <.score team="axis" label={@headings["axis"]} value={@axis} size="xl" />
            </div>
            <.sectors allied={@allied} size="lg" class="w-full max-w-[26.25rem]" />
            <span :if={@time_left} class="font-mono text-[0.9375rem] tabular-nums">
              {@time_left} <span class="text-subtle">{gettext("left")}</span>
            </span>
          </div>

          <div :if={@ready?} class="flex flex-col justify-end gap-3.5">
            <div class="live-glass flex flex-col gap-3 rounded-[1.25rem] px-4.5 py-4">
              <div class="flex items-baseline justify-between">
                <span class="text-[0.8125rem] text-subtle">{gettext("Players")}</span>
                <.head_count players={@players} max={@max_players} class="text-[1.375rem]" />
              </div>
              <.balance allies={@allied_players} axis={@axis_players} class="h-2" />
              <div class="flex justify-between gap-2 text-[0.8125rem]">
                <span class="text-allies">{@allied_players} {@teams["allies"]}</span>
                <span class="text-axis">{@axis_players} {@teams["axis"]}</span>
              </div>
            </div>
            <div :if={@queue || @vips} class="grid grid-cols-2 gap-2.5">
              <div :if={@queue} class="live-glass rounded-2xl px-4 py-3">
                <div class="text-xs text-subtle">{elem(@queue, 0)}</div>
                <div class="font-display text-[1.375rem] font-semibold tabular-nums">
                  {elem(@queue, 1)}
                </div>
              </div>
              <div :if={@vips} class="live-glass rounded-2xl px-4 py-3">
                <div class="text-xs text-subtle">{gettext("VIPs playing")}</div>
                <div class="font-display text-[1.375rem] font-semibold tabular-nums">{@vips}</div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Tablet: the map beside the score, the head count under both. --%>
        <div class="hidden h-[17.5rem] grid-cols-[minmax(0,1fr)_auto] grid-rows-[minmax(0,1fr)_auto] gap-x-6 gap-y-4.5 px-7 py-6 md:grid xl:hidden">
          <div class="flex min-w-0 flex-col gap-2">
            <.live_pill stream_status={@stream_status} label={gettext("Live match")} />
            <h2 class="mt-1.5 truncate font-display text-[3.25rem] font-bold leading-[0.95] tracking-[-0.035em]">
              <.map_title map={@map} loading?={@loading?} error?={@error?} />
            </h2>
            <span :if={@ready?} class="truncate text-[0.9375rem] text-base-content/80">
              {mode_line(@mode, @started)}
            </span>
            <span :if={@ready? and @time_left} class="mt-1 font-mono text-sm tabular-nums">
              {@time_left} <span class="text-subtle">{gettext("left")}</span>
            </span>
          </div>

          <div :if={@ready?} class="flex flex-col items-center justify-center gap-3">
            <div class="flex items-center gap-5.5">
              <.score team="allies" label={@headings["allies"]} value={@allied} size="lg" />
              <span class="font-display text-[2.125rem] text-base-content/40" aria-hidden="true">
                :
              </span>
              <.score team="axis" label={@headings["axis"]} value={@axis} size="lg" />
            </div>
            <.sectors allied={@allied} size="md" class="w-60" />
          </div>

          <div
            :if={@ready?}
            class="col-span-2 grid grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)_minmax(0,1fr)] gap-2.5"
          >
            <div class="live-glass flex flex-col gap-1.5 rounded-2xl px-3.5 py-2.5">
              <div class="flex justify-between gap-2 text-xs">
                <span class="text-allies">{@allied_players} {@teams["allies"]}</span>
                <span class="text-subtle tabular-nums">
                  {@players}<span :if={@max_players}>/{@max_players}</span>
                </span>
                <span class="text-axis">{@axis_players} {@teams["axis"]}</span>
              </div>
              <.balance allies={@allied_players} axis={@axis_players} class="h-1.5" />
            </div>
            <div
              :if={@queue}
              class="live-glass flex items-center justify-between rounded-2xl px-3.5 py-2"
            >
              <span class="text-xs text-subtle">{elem(@queue, 0)}</span>
              <span class="font-display text-xl font-semibold tabular-nums">{elem(@queue, 1)}</span>
            </div>
            <div
              :if={@vips}
              class="live-glass flex items-center justify-between rounded-2xl px-3.5 py-2"
            >
              <span class="text-xs text-subtle">{gettext("VIPs playing")}</span>
              <span class="font-display text-xl font-semibold tabular-nums">{@vips}</span>
            </div>
          </div>
        </div>

        <%!-- Phone: the score at the bottom of the picture. --%>
        <div class="flex h-[14.75rem] flex-col gap-1.5 px-5 py-4.5 md:hidden">
          <div class="flex items-center justify-between gap-3">
            <.live_pill stream_status={@stream_status} label={gettext("Live")} size="sm" />
            <span :if={@ready? and @time_left} class="font-mono text-[0.8125rem] tabular-nums">
              {@time_left}
            </span>
          </div>
          <span class="grow"></span>
          <span class="truncate text-[0.8125rem] text-base-content/80">
            <.map_title map={@map} loading?={@loading?} error?={@error?} />
            <span :if={@ready?}>· {mode_label(@mode)}</span>
          </span>
          <div :if={@ready?} class="flex items-end justify-between gap-3">
            <div class="flex items-baseline gap-3">
              <span class="font-display text-[4rem] font-bold leading-[0.9] text-allies tabular-nums">
                {@allied}
              </span>
              <span class="font-display text-[1.75rem] text-base-content/40" aria-hidden="true">
                :
              </span>
              <span class="font-display text-[4rem] font-bold leading-[0.9] text-axis tabular-nums">
                {@axis}
              </span>
            </div>
            <div class="flex flex-col items-end gap-0.5">
              <.head_count players={@players} max={@max_players} class="text-xl" />
              <span class="text-xs text-subtle">
                <span class="text-allies">{@allied_players}</span>
                · <span class="text-axis">{@axis_players}</span>
              </span>
            </div>
          </div>
          <.sectors :if={@ready?} allied={@allied} size="sm" class="mt-2" />
        </div>
      <% end %>
    </section>
    """
  end

  # The leaderboard's strip: one row from md up, stacked on a phone.
  defp hero_strip(assigns) do
    ~H"""
    <div class="grid items-center gap-4 px-5 py-4 md:h-24 md:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] md:gap-7 md:px-6.5 md:py-0">
      <div class="flex min-w-0 items-center gap-4">
        <.live_pill stream_status={@stream_status} label={gettext("Live")} />
        <span class="flex min-w-0 flex-col">
          <strong class="truncate font-display text-[1.75rem] font-bold leading-[1.05] tracking-[-0.02em]">
            <.map_title map={@map} loading?={@loading?} error?={@error?} />
          </strong>
          <span :if={@ready?} class="truncate text-[0.8125rem] text-base-content/80">
            {mode_line(@mode, @started)}
          </span>
        </span>
      </div>

      <div :if={@ready?} class="flex items-center justify-center gap-4.5">
        <span class="hidden text-xs font-semibold tracking-[0.06em] text-allies uppercase sm:inline">
          {@headings["allies"]}
        </span>
        <span class="font-display text-[2.75rem] font-bold leading-none text-allies tabular-nums">
          {@allied}
        </span>
        <span class="flex flex-col items-center gap-1.5">
          <.sectors allied={@allied} size="sm" class="w-[9.375rem]" />
          <span :if={@time_left} class="font-mono text-xs tabular-nums">
            {@time_left} <span class="text-subtle">{gettext("left")}</span>
          </span>
        </span>
        <span class="font-display text-[2.75rem] font-bold leading-none text-axis tabular-nums">
          {@axis}
        </span>
        <span class="hidden text-xs font-semibold tracking-[0.06em] text-axis uppercase sm:inline">
          {@headings["axis"]}
        </span>
      </div>

      <div :if={@ready?} class="flex items-center gap-4 md:justify-end">
        <div class="flex w-full flex-col gap-1.5 md:w-[11.875rem]">
          <div class="flex justify-between gap-2 text-xs">
            <span class="text-allies">{@allied_players} {@teams["allies"]}</span>
            <span class="font-semibold tabular-nums">
              {@players}<span :if={@max_players}>/{@max_players}</span>
            </span>
            <span class="text-axis">{@axis_players} {@teams["axis"]}</span>
          </div>
          <.balance allies={@allied_players} axis={@axis_players} class="h-1.5" />
        </div>
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  attr :team, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :size, :string, required: true, values: ~w(lg xl)

  defp score(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <span class={[
        "font-semibold tracking-[0.06em] uppercase",
        if(@size == "xl", do: "text-[0.8125rem]", else: "text-xs"),
        team_text(@team)
      ]}>
        {@label}
      </span>
      <span class={[
        "font-display font-bold leading-none tabular-nums",
        if(@size == "xl", do: "text-[6.5rem]", else: "text-[5.5rem]"),
        team_text(@team)
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  attr :players, :integer, required: true
  attr :max, :integer, default: nil
  attr :class, :any, default: nil

  defp head_count(assigns) do
    ~H"""
    <span class={["font-display font-semibold tabular-nums", @class]}>
      {@players}<span :if={@max} class="text-sm font-normal text-muted">/{@max}</span>
    </span>
    """
  end

  @doc """
  The five sectors of a warfare match, coloured by who holds them - drawn
  here at the sizes of the hero (`lg` the wide one, `md` the tablet's, `sm`
  the phone's and the strip's).
  """
  attr :allied, :integer, required: true
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  def sectors(assigns) do
    assigns = assign(assigns, :allied, assigns.allied |> max(0) |> min(5))

    ~H"""
    <div
      class={[
        "grid grid-cols-5",
        case @size do
          "lg" -> "gap-1.5"
          "md" -> "gap-[5px]"
          _sm -> "gap-1"
        end,
        @class
      ]}
      role="img"
      aria-label={gettext("Allies hold %{allied} of %{total} sectors", allied: @allied, total: 5)}
    >
      <span
        :for={index <- 1..5}
        class={[
          case @size do
            "lg" -> "h-3 rounded-[5px]"
            "md" -> "h-2.5 rounded-[5px]"
            _sm -> "h-2 rounded"
          end,
          if(index <= @allied, do: "bg-allies", else: "bg-axis")
        ]}
      ></span>
    </div>
    """
  end

  attr :allies, :integer, required: true
  attr :axis, :integer, required: true
  attr :class, :any, default: nil

  defp balance(assigns) do
    ~H"""
    <div
      class={["flex gap-[3px] overflow-hidden rounded", @class]}
      role="img"
      aria-label={gettext("%{allies} Allies, %{axis} Axis", allies: @allies, axis: @axis)}
    >
      <span class="rounded-[inherit] bg-allies" style={"flex-grow: #{max(@allies, 1)}"}></span>
      <span class="rounded-[inherit] bg-axis" style={"flex-grow: #{max(@axis, 1)}"}></span>
    </div>
    """
  end

  attr :stream_status, :any, required: true
  attr :label, :string, required: true
  attr :size, :string, default: "md", values: ~w(sm md)

  defp live_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 self-start rounded-full text-xs font-semibold",
      if(@size == "sm", do: "h-6.5 px-2.5", else: "h-7 px-3"),
      if(@stream_status == :connected,
        do: "bg-primary/16 text-primary",
        else: "bg-white/10 text-subtle"
      )
    ]}>
      <span
        class={[
          "shrink-0 rounded-full bg-current",
          if(@size == "sm", do: "size-1.5", else: "size-[7px]")
        ]}
        aria-hidden="true"
      ></span>
      {@label}
    </span>
    """
  end

  attr :map, :string, default: nil
  attr :loading?, :boolean, default: false
  attr :error?, :boolean, default: false

  defp map_title(assigns) do
    ~H"""
    <%= cond do %>
      <% @loading? -> %>
        <span class="inline-block h-[0.9em] w-56 max-w-full animate-pulse rounded-field bg-white/15"></span>
      <% @error? -> %>
        {gettext("CRCON is not answering")}
      <% true -> %>
        {@map || gettext("Unknown map")}
    <% end %>
    """
  end

  # "Warfare · started at 21:02", or the mode alone when CRCON did not say.
  defp mode_line(mode, nil), do: mode_label(mode)

  defp mode_line(mode, started),
    do: mode_label(mode) <> " · " <> gettext("started at %{time}", time: started)

  # The start in the server's own time zone, the clock its players live by.
  defp started_label(%DateTime{} = at, server) do
    zone = Map.get(server, :timezone) || "Etc/UTC"

    at =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        {:error, _reason} -> at
      end

    Calendar.strftime(at, "%H:%M")
  end

  defp started_label(_at, _server), do: nil

  # CRCON writes "0:47:12"; the hour goes when there is none.
  defp time_left(raw) when is_binary(raw) do
    case String.split(raw, ":") do
      ["0", minutes, seconds] -> "#{minutes}:#{seconds}"
      _other -> raw
    end
  end

  defp time_left(_raw), do: nil

  defp stream_phrase(:connected), do: gettext("Log stream connected")
  defp stream_phrase(:connecting), do: gettext("Log stream connecting")
  defp stream_phrase({:error, _reason}), do: gettext("Log stream down")
  defp stream_phrase(_status), do: gettext("Log stream off")

  # ── The feed ───────────────────────────────────────────────────────────────

  @doc """
  The chips over a feed: everything, kills, chat, only where a rule acted -
  and the pause button. `compact` (tablet and phone) keeps everything and
  where rules acted.
  """
  attr :id, :string, required: true
  attr :filter, :string, required: true
  attr :paused?, :boolean, required: true
  attr :pause_event, :string, required: true
  attr :filter_event, :string, required: true
  attr :class, :any, default: nil

  def feed_filters(assigns) do
    ~H"""
    <div id={@id} class={["flex items-center gap-2", @class]}>
      <.chip filter="all" current={@filter} event={@filter_event}>{gettext("All")}</.chip>
      <.chip filter="kills" current={@filter} event={@filter_event} class="hidden xl:flex">
        {gettext("Kills")}
      </.chip>
      <.chip filter="chat" current={@filter} event={@filter_event} class="hidden xl:flex">
        {gettext("Chat")}
      </.chip>
      <.chip filter="acted" current={@filter} event={@filter_event}>
        <span class="hidden xl:inline">{gettext("Only where rules acted")}</span>
        <span class="xl:hidden">{gettext("Rules acted")}</span>
      </.chip>
      <button
        id={"#{@id}-pause"}
        type="button"
        phx-click={@pause_event}
        aria-pressed={to_string(@paused?)}
        aria-label={if @paused?, do: gettext("Resume the feed"), else: gettext("Pause the feed")}
        title={if @paused?, do: gettext("Resume the feed"), else: gettext("Pause the feed")}
        class={[
          "flex size-9 shrink-0 cursor-pointer items-center justify-center rounded-full border transition-colors xl:size-8.5",
          if(@paused?,
            do: "border-warning/45 bg-warning/13 text-warning",
            else:
              "border-base-300 bg-white hover:bg-base-200 dark:bg-secondary dark:hover:bg-base-300"
          )
        ]}
      >
        <.icon name={if @paused?, do: "hero-play-solid", else: "hero-pause-solid"} class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :filter, :string, required: true
  attr :current, :string, required: true
  attr :event, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <button
      id={"feed-chip-#{@filter}"}
      type="button"
      phx-click={@event}
      phx-value-filter={@filter}
      aria-pressed={to_string(@filter == @current)}
      class={[
        "flex h-9 shrink-0 cursor-pointer items-center whitespace-nowrap rounded-full border px-3 text-xs transition-colors xl:h-8.5",
        if(@filter == @current,
          do:
            "border-transparent bg-base-content font-semibold text-base-100 dark:border-primary/45 dark:bg-primary/10 dark:text-primary",
          else:
            "border-base-300 bg-white font-medium hover:bg-base-200 dark:bg-secondary dark:hover:bg-base-300"
        ),
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  A feed row built from a CRCON event. `roster` (the live snapshot's
  players, when the page has one) colours the names by team when the log
  line itself does not say, and gives a joining player's level and session
  count and a leaving player's time on the server.
  """
  @spec event_row(struct(), String.t(), keyword()) :: map()
  def event_row(event, id, opts \\ []) do
    roster = Keyword.get(opts, :roster)
    {actor_team, target_team} = kill_teams(event)

    %{
      id: id,
      kind: :event,
      key: LiveFeed.event_key(event),
      type: event.type,
      occurred_at: event.occurred_at,
      server_name: Keyword.get(opts, :server_name),
      player_id: event.player_id,
      actor: event.player_name,
      actor_team: team_key(event.chat_team) || actor_team || roster_team(roster, event.player_id),
      target: event.target_player_name,
      target_team: target_team || roster_team(roster, event.target_player_id),
      weapon: event.weapon,
      message:
        event.chat_message ||
          (event.type not in [:player_kill, :player_team_kill] && event.message) || nil,
      chat_scope: event.chat_scope,
      command?:
        event.type == :player_chat and
          HllConditionalActions.Engine.Context.command?(event.chat_message),
      details: details(event, roster),
      acted: [],
      ticket: nil
    }
  end

  @doc """
  A joining player's level and session, a leaving one's time on the server,
  from the roster; `%{}` when the roster does not know them (yet).
  """
  @spec details(struct(), map() | nil) :: map()
  def details(%{type: type, player_id: player_id}, roster)
      when type in [:player_connected, :player_disconnected] and is_map(roster) do
    case Map.get(roster, player_id) do
      %{} = player ->
        profile = if is_map(player["profile"]), do: player["profile"], else: %{}

        %{
          level: positive(player["level"]),
          sessions: positive(profile["sessions_count"]),
          played:
            positive(player["current_playtime_seconds"] || profile["current_playtime_seconds"])
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      _unknown ->
        %{}
    end
  end

  def details(_event, _roster), do: %{}

  @doc """
  A feed row built from a rule execution that came from no line of the
  feed (a periodic rule, a line older than the feed): who the rule acted on
  and the rule itself, as a pill that opens it.
  """
  @spec execution_row(struct(), map() | nil) :: map()
  def execution_row(execution, rule) do
    annotation = LiveFeed.annotation(execution, rule)

    %{
      id: "execution-#{execution.id}",
      kind: :execution,
      key: nil,
      occurred_at: execution.executed_at,
      player: execution.player_name,
      acted: [annotation]
    }
  end

  # CRCON writes the team of both players into a kill line:
  # "Chris(Allies/7656…) -> Muctar(Axis/7656…) with M1 GARAND".
  defp kill_teams(%{type: type} = event) when type in [:player_kill, :player_team_kill] do
    text = Enum.find([event.message, get_in(event.raw || %{}, ["raw"])], &is_binary/1) || ""

    case Regex.scan(~r/\((Allies|Axis)\//i, text, capture: :all_but_first) do
      [[actor], [target] | _rest] -> {team_key(actor), team_key(target)}
      [[actor]] -> {team_key(actor), nil}
      _none -> {nil, nil}
    end
  end

  defp kill_teams(_event), do: {nil, nil}

  defp roster_team(roster, player_id) when is_map(roster) and is_binary(player_id) do
    case Map.get(roster, player_id) do
      %{"team" => team} -> team_key(team)
      _other -> nil
    end
  end

  defp roster_team(_roster, _player_id), do: nil

  @doc """
  One line of the feed. `row` comes from `event_row/3` or `execution_row/2`.

  Four columns from `md` up - time, icon, the sentence, the rule's pill -
  and two on a phone, where the time is shorter and the pill goes under
  the sentence.
  """
  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :base, :string, default: nil, doc: "the server's path, for the ticket link"
  attr :show_server, :boolean, default: false

  def feed_row(%{row: %{kind: :execution}} = assigns) do
    assigns = assign(assigns, :annotation, hd(assigns.row.acted))

    ~H"""
    <div
      id={@id}
      data-kind="execution"
      class={["live-feed-row", tint(@row)]}
    >
      <.clock id={"#{@id}-at"} at={@row.occurred_at} />
      <span class={["max-md:hidden", status_text(@annotation.status)]}>
        <.icon name="hero-bolt" class="size-[1.125rem]" />
      </span>
      <span class="min-w-0 text-[0.8125rem] md:text-sm">
        <.execution_sentence annotation={@annotation} />
        <.pills acted={@row.acted} class="mt-1 md:hidden" />
      </span>
      <.pills acted={@row.acted} class="max-md:hidden" />
    </div>
    """
  end

  def feed_row(assigns) do
    ~H"""
    <div id={@id} data-kind={@row.type} class={["live-feed-row", tint(@row)]}>
      <.clock id={"#{@id}-at"} at={@row.occurred_at} />
      <span
        class={["max-md:hidden", if(@row.ticket, do: "text-primary", else: event_text(@row.type))]}
        title={Labels.event_type(@row.type)}
      >
        <.crosshair :if={@row.type in [:player_kill, :player_team_kill]} />
        <.icon
          :if={@row.type not in [:player_kill, :player_team_kill]}
          name={event_icon(@row)}
          class="size-[1.125rem]"
        />
      </span>
      <span class="min-w-0 break-words text-[0.8125rem] md:text-sm">
        <.event_sentence row={@row} />
        <span :if={@show_server && @row.server_name} class="text-muted">
          · {@row.server_name}
        </span>
        <span :if={@row.acted != [] or @row.ticket} class="mt-1 flex flex-wrap gap-1.5 md:hidden">
          <.pills acted={@row.acted} />
          <.ticket_pill :if={@row.ticket} ticket={@row.ticket} />
        </span>
      </span>
      <span :if={@row.acted != [] or @row.ticket} class="flex gap-1.5 max-md:hidden">
        <.pills acted={@row.acted} />
        <.ticket_pill :if={@row.ticket} ticket={@row.ticket} />
      </span>
    </div>
    """
  end

  # The crosshair of a kill line; Heroicons has none (see the Handoff
  # board's own icons).
  defp crosshair(assigns) do
    ~H"""
    <svg
      class="size-[1.125rem]"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="7.5" /><path d="M12 2v5M12 17v5M2 12h5M17 12h5" />
    </svg>
    """
  end

  # The time of a line: hours, minutes and - from md up - seconds, in the
  # viewer's own time zone.
  attr :id, :string, required: true
  attr :at, :any, required: true

  defp clock(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={@at && DateTime.to_iso8601(@at)}
      phx-hook=".FeedClock"
      class="whitespace-nowrap pt-px font-mono text-[0.6875rem] text-muted tabular-nums md:pt-0 md:text-xs"
    ><span data-hm>{@at && Calendar.strftime(@at, "%H:%M")}</span><span
      data-s
      class="max-md:hidden"
    >{@at && Calendar.strftime(@at, ":%S")}</span></time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FeedClock">
      export default {
        mounted() { this.render() },
        updated() { this.render() },
        render() {
          const value = this.el.getAttribute("datetime")
          if (!value) return
          const parts = new Intl.DateTimeFormat(document.documentElement.lang || "en", {
            hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23"
          }).formatToParts(new Date(value))
          const get = (type) => (parts.find((p) => p.type === type) || {}).value || "00"
          this.el.querySelector("[data-hm]").textContent = `${get("hour")}:${get("minute")}`
          this.el.querySelector("[data-s]").textContent = `:${get("second")}`
        }
      }
    </script>
    """
  end

  attr :acted, :list, required: true
  attr :class, :any, default: nil

  defp pills(assigns) do
    ~H"""
    <span :if={@acted != []} class={["flex flex-wrap gap-1.5", @class]}>
      <.link
        :for={annotation <- Enum.take(@acted, 2)}
        navigate={"/rules/#{annotation.rule_id}"}
        class={[
          "inline-flex h-5.5 max-w-full items-center truncate rounded-full px-2 text-[0.6875rem] font-semibold transition-opacity hover:opacity-85 md:h-6.5 md:px-2.5 md:text-xs",
          pill_tone(annotation.status)
        ]}
      >
        <span class="xl:hidden">{pill_label(annotation, :short)}</span>
        <span class="hidden xl:inline">{pill_label(annotation)}</span>
      </.link>
      <span
        :if={length(@acted) > 2}
        class="inline-flex h-5.5 items-center rounded-full bg-secondary px-2 text-[0.6875rem] font-semibold text-subtle md:h-6.5 md:text-xs"
      >
        +{length(@acted) - 2}
      </span>
    </span>
    """
  end

  attr :ticket, :map, required: true

  defp ticket_pill(assigns) do
    ~H"""
    <.link
      navigate={"/tickets/#{@ticket.id}"}
      class="inline-flex h-5.5 items-center whitespace-nowrap rounded-full bg-primary/12 px-2 text-[0.6875rem] font-semibold text-primary transition-opacity hover:opacity-85 md:h-6.5 md:px-2.5 md:text-xs"
    >
      <span class="xl:hidden">{gettext("Ticket #%{id}", id: @ticket.id)}</span>
      <span class="hidden xl:inline">{gettext("Ticket #%{id} opened", id: @ticket.id)}</span>
    </.link>
    """
  end

  @doc """
  The words on the pill of a rule that acted: its name, then how it ended
  when that is not plain success, and the rung of a ladder.
  """
  @spec pill_label(map(), :full | :short) :: String.t()
  def pill_label(annotation, length \\ :full)

  # The tablet's and the phone's: a rung needs no "simulated" before it,
  # the pill's colour says so.
  def pill_label(%{status: :simulated, step: step} = annotation, :short) when is_integer(step),
    do: gettext("%{rule} · step %{step}", rule: rule_name(annotation), step: step)

  def pill_label(annotation, _length) do
    name = rule_name(annotation)

    case {annotation.status, annotation.step} do
      {:simulated, nil} -> gettext("%{rule} · simulated", rule: name)
      {:simulated, step} -> gettext("%{rule} · simulated step %{step}", rule: name, step: step)
      {:failed, _step} -> gettext("%{rule} · failed", rule: name)
      {:partial, _step} -> gettext("%{rule} · partly failed", rule: name)
      {_executed, nil} -> name
      {_executed, step} -> gettext("%{rule} · step %{step}", rule: name, step: step)
    end
  end

  defp rule_name(%{rule_name: nil}), do: gettext("Deleted rule")
  defp rule_name(%{rule_name: name}), do: name

  defp pill_tone(:simulated), do: "bg-accent/13 text-accent"
  defp pill_tone(:failed), do: "bg-error/14 text-error"
  defp pill_tone(:partial), do: "bg-warning/13 text-warning"
  defp pill_tone(_executed), do: "bg-primary/12 text-primary"

  # The tint of a line follows what acted on it: the engine's lavender for a
  # simulation, the signal for a rule that acted or a ticket, the danger
  # tones for a failure.
  defp tint(%{acted: [_ | _] = acted}) do
    statuses = Enum.map(acted, & &1.status)

    cond do
      :failed in statuses ->
        "live-feed-row-acted bg-error/5"

      :partial in statuses ->
        "live-feed-row-acted bg-warning/5"

      Enum.all?(statuses, &(&1 == :simulated)) ->
        "live-feed-row-acted bg-secondary-300/16 dark:bg-accent/5"

      true ->
        "live-feed-row-acted bg-primary-300/18 dark:bg-primary/4"
    end
  end

  defp tint(%{ticket: %{}}), do: "live-feed-row-acted bg-primary-300/18 dark:bg-primary/4"
  defp tint(_row), do: nil

  attr :annotation, :map, required: true

  defp execution_sentence(assigns) do
    ~H"""
    <%= case action_sentence(@annotation.action, @annotation.status) do %>
      <% {:player, text} -> %>
        {text} <strong class="font-semibold">{@annotation.player || gettext("the server")}</strong>
      <% {:alone, text} -> %>
        {text}
    <% end %>
    """
  end

  # What a rule did, as the start of a sentence the player's name ends.
  defp action_sentence(_action, :failed), do: {:player, gettext("A rule failed to act on")}

  defp action_sentence(action, :simulated), do: simulated_sentence(action)
  defp action_sentence(action, _status), do: acted_sentence(action)

  defp simulated_sentence("message_player"), do: {:player, gettext("Would send a message to")}

  defp simulated_sentence("message_all_players"),
    do: {:alone, gettext("Would message every player")}

  defp simulated_sentence(_other), do: {:player, gettext("Simulated on")}

  defp acted_sentence("message_player"), do: {:player, gettext("Message sent to")}

  defp acted_sentence("message_all_players"),
    do: {:alone, gettext("Message sent to every player")}

  defp acted_sentence("punish_player"), do: {:player, gettext("Punished")}
  defp acted_sentence("kick_player"), do: {:player, gettext("Kicked")}
  defp acted_sentence("temp_ban_player"), do: {:player, gettext("Temporarily banned")}
  defp acted_sentence("perma_ban_player"), do: {:player, gettext("Banned")}
  defp acted_sentence("switch_player_team"), do: {:player, gettext("Switched to the other team:")}

  defp acted_sentence("switch_player_on_death"),
    do: {:player, gettext("Switches team on death:")}

  defp acted_sentence("add_to_watchlist"), do: {:player, gettext("Put on the watchlist:")}
  defp acted_sentence("open_ticket"), do: {:player, gettext("Ticket opened for")}
  defp acted_sentence("grant_vip"), do: {:player, gettext("VIP granted to")}
  defp acted_sentence("send_discord_webhook"), do: {:player, gettext("Discord told about")}
  defp acted_sentence(_other), do: {:player, gettext("A rule acted on")}

  attr :row, :map, required: true

  defp event_sentence(%{row: %{type: :player_kill}} = assigns) do
    ~H"""
    <.name name={@row.actor} team={@row.actor_team} />
    {gettext("killed")}
    <.name name={@row.target} team={@row.target_team} />
    <span :if={@row.weapon} class="text-muted">· {@row.weapon}</span>
    """
  end

  defp event_sentence(%{row: %{type: :player_team_kill}} = assigns) do
    ~H"""
    <.name name={@row.actor} team={@row.actor_team} />
    {gettext("killed a teammate,")}
    <.name name={@row.target} team={@row.target_team || @row.actor_team} />
    <span :if={@row.weapon} class="text-muted">· {@row.weapon}</span>
    """
  end

  defp event_sentence(%{row: %{type: :player_chat, command?: true}} = assigns) do
    ~H"""
    <.name name={@row.actor} team={@row.actor_team} />
    <span class="font-mono text-xs text-base-content/80 md:text-[0.8125rem]">{@row.message}</span>
    """
  end

  defp event_sentence(%{row: %{type: :player_chat}} = assigns) do
    ~H"""
    <.name name={@row.actor} team={@row.actor_team} />
    <span class="text-muted">{chat_scope(@row.chat_scope)}:</span>
    {@row.message}
    """
  end

  defp event_sentence(%{row: %{type: :player_connected}} = assigns) do
    ~H"""
    <strong class="font-semibold">{@row.actor || "–"}</strong>
    {gettext("joined the server")}
    <span :if={@row.details[:level]} class="text-muted">
      · {gettext("level %{level}", level: @row.details.level)}
    </span>
    <span :if={@row.details[:sessions]} class="text-muted">
      · {gettext("session #%{count}", count: @row.details.sessions)}
    </span>
    """
  end

  defp event_sentence(%{row: %{type: :player_disconnected}} = assigns) do
    ~H"""
    <strong class="font-semibold">{@row.actor || "–"}</strong>
    {gettext("left the server")}
    <span :if={@row.details[:played]} class="text-muted">
      · {gettext("played %{time}", time: played(@row.details.played))}
    </span>
    """
  end

  defp event_sentence(%{row: %{type: :team_switch}} = assigns) do
    ~H"""
    <.name name={@row.actor} team={@row.actor_team} /> {gettext("switched teams")}
    <span :if={@row.message} class="text-muted">· {@row.message}</span>
    """
  end

  defp event_sentence(%{row: %{type: type}} = assigns) when type in [:match_start, :match_end] do
    ~H"""
    <strong class="font-semibold">{Labels.event_type(@row.type)}</strong>
    <span :if={@row.message} class="text-muted">· {@row.message}</span>
    """
  end

  defp event_sentence(assigns) do
    ~H"""
    <strong class="font-semibold">{Labels.event_type(@row.type)}</strong>
    <.name :if={@row.actor} name={@row.actor} team={@row.actor_team} />
    <span :if={@row.message} class="text-muted">· {@row.message}</span>
    """
  end

  attr :name, :string, default: nil
  attr :team, :string, default: nil

  defp name(assigns) do
    ~H"""
    <strong class={["font-semibold", team_text(@team)]}>{@name || "–"}</strong>
    """
  end

  defp chat_scope(nil), do: gettext("to everyone")

  defp chat_scope(scope) do
    case String.downcase(scope) do
      "team" -> gettext("in the team")
      "unit" -> gettext("in the squad")
      _other -> scope
    end
  end

  # "1h12" past an hour, "34 min" under it.
  defp played(seconds) when seconds >= 3600,
    do:
      "#{div(seconds, 3600)}h#{seconds |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  defp played(seconds), do: gettext("%{minutes} min", minutes: max(div(seconds, 60), 1))

  @doc "The icon of a CRCON event type in the feed."
  @spec event_icon(map() | atom()) :: String.t()
  def event_icon(%{type: :player_chat, command?: true}), do: "hero-command-line"
  def event_icon(%{type: type}), do: event_icon(type)
  def event_icon(:player_kill), do: "hero-viewfinder-circle"
  def event_icon(:player_team_kill), do: "hero-viewfinder-circle"
  def event_icon(:player_chat), do: "hero-chat-bubble-bottom-center-text"
  def event_icon(:player_connected), do: "hero-arrow-right-end-on-rectangle"
  def event_icon(:player_disconnected), do: "hero-arrow-left-start-on-rectangle"
  def event_icon(:team_switch), do: "hero-arrows-right-left"
  def event_icon(:match_start), do: "hero-play"
  def event_icon(:match_end), do: "hero-flag"
  def event_icon(:admin_action), do: "hero-shield-check"
  def event_icon(:camera), do: "hero-video-camera"
  def event_icon(:vote), do: "hero-hand-raised"
  def event_icon(_type), do: "hero-information-circle"

  defp event_text(:player_team_kill), do: "text-error"
  defp event_text(type) when type in [:match_start, :match_end], do: "text-primary"
  defp event_text(:admin_action), do: "text-warning"
  defp event_text(_type), do: "text-subtle"

  defp status_text(:simulated), do: "text-accent"
  defp status_text(:failed), do: "text-error"
  defp status_text(:partial), do: "text-warning"
  defp status_text(_executed), do: "text-primary"

  # ── Rankings ───────────────────────────────────────────────────────────────

  @doc """
  A player's (or squad's) initials on the tint of their team.
  """
  attr :name, :string, required: true
  attr :team, :any, default: nil
  attr :size, :string, default: "md", values: ~w(sm md lg)

  def initials_tile(assigns) do
    ~H"""
    <span
      class={[
        "flex shrink-0 items-center justify-center font-bold",
        case @size do
          "sm" -> "size-8.5 rounded-[0.6875rem] text-xs"
          "lg" -> "size-9.5 rounded-xl text-[0.8125rem]"
          _md -> "size-9 rounded-xl text-[0.8125rem]"
        end,
        team_tint(team_key(@team))
      ]}
      aria-hidden="true"
    >
      {initials(@name)}
    </span>
    """
  end

  defp team_tint("allies"), do: "bg-allies/14 text-allies"
  defp team_tint("axis"), do: "bg-axis/16 text-axis"
  defp team_tint(_none), do: "bg-secondary text-subtle"

  @doc """
  The first letters of a name, for `initials_tile/1`: "Kowalski [7DV]"
  gives "KO", "Cpt. Nogueira" gives "CN".
  """
  @spec initials(String.t() | nil) :: String.t()
  def initials(nil), do: "?"

  def initials(name) do
    words =
      name
      |> String.replace(~r/\[[^\]]*\]/u, " ")
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case words do
      [] -> name |> String.slice(0, 2) |> String.upcase()
      [word] -> word |> String.slice(0, 2) |> String.upcase()
      [first, second | _rest] -> String.upcase(String.first(first) <> String.first(second))
    end
  end

  @doc """
  One leaderboard category: the podium, each player on their team's tint,
  the leader's number in the display face.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, default: nil, doc: "a word right of the title: a floor, a unit"
  attr :icon, :string, default: "hero-trophy"
  attr :rows, :list, required: true, doc: "maps of %{name, team, value}, best first"
  attr :teams, :map, required: true, doc: "from team_names/1"

  def rank_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="flex min-w-0 flex-col gap-2.5 rounded-[1.375rem] bg-base-100 px-4.5 py-4 shadow-[0_1px_2px_rgb(22_23_15/0.05)] dark:shadow-none"
    >
      <header class="flex items-center gap-2.5">
        <span class="flex size-7.5 shrink-0 items-center justify-center rounded-[0.625rem] bg-secondary text-subtle">
          <.icon name={@icon} class="size-4" />
        </span>
        <h3 class="min-w-0 flex-1 truncate text-[0.9375rem] font-semibold">{@title}</h3>
        <span :if={@note} class="shrink-0 text-xs text-muted">{@note}</span>
      </header>

      <p :if={@rows == []} class="py-4 text-center text-xs text-muted">
        {gettext("Nobody ranked yet")}
      </p>

      <ol :if={@rows != []} class="flex flex-col gap-2.5">
        <li
          :for={{row, index} <- Enum.with_index(@rows, 1)}
          class="grid grid-cols-[1.25rem_2.125rem_minmax(0,1fr)_auto] items-center gap-2.5"
        >
          <span class={["font-mono text-xs", if(index == 1, do: "text-primary", else: "text-muted")]}>
            {String.pad_leading(to_string(index), 2, "0")}
          </span>
          <.initials_tile name={row.name} team={row.team} size="sm" />
          <span class="flex min-w-0 flex-col">
            <strong class="truncate text-sm font-semibold">{row.name}</strong>
            <span class={["truncate text-xs", team_text(team_key(row.team))]}>
              {Map.get(@teams, team_key(row.team) || "", "–")}
            </span>
          </span>
          <span class={[
            "font-display font-semibold tabular-nums",
            if(index == 1, do: "text-2xl", else: "text-lg text-subtle")
          ]}>
            {row.value}
          </span>
        </li>
      </ol>
    </article>
    """
  end

  @doc """
  A number the way the boards write it: the locale's thousands separator
  and two decimals for a ratio - "2,140" and "3.63" in English, "2.140" and
  "3,63" in Portuguese.

      iex> HllConditionalActionsWeb.LiveComponents.format_number(2140)
      "2,140"
      iex> HllConditionalActionsWeb.LiveComponents.format_number(3.625)
      "3.63"
  """
  @spec format_number(term()) :: String.t()
  def format_number(value) when is_float(value) do
    {_thousands, decimal} = separators()
    [whole, decimals] = value |> :erlang.float_to_binary(decimals: 2) |> String.split(".")
    group(whole) <> decimal <> decimals
  end

  def format_number(value) when is_integer(value), do: group(Integer.to_string(value))
  def format_number(value), do: to_string(value)

  defp group("-" <> digits), do: "-" <> group(digits)
  defp group(digits) when byte_size(digits) <= 3, do: digits

  defp group(digits) do
    {thousands, _decimal} = separators()

    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(thousands, &Enum.join/1)
    |> String.reverse()
  end

  defp separators, do: HllConditionalActionsWeb.NumberFormat.separators()

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc "The label of a game mode as CRCON reports it."
  @spec mode_label(term()) :: String.t()
  def mode_label(nil), do: gettext("Unknown mode")

  def mode_label(mode) do
    case to_string(mode) do
      "warfare" -> gettext("Warfare")
      "offensive" -> gettext("Offensive")
      "skirmish" -> gettext("Skirmish")
      other -> String.capitalize(other)
    end
  end

  @doc "The pretty name of the map of a game state, or nil."
  @spec map_name(map()) :: String.t() | nil
  def map_name(gamestate) do
    case gamestate["current_map"] do
      %{"map" => %{"pretty_name" => name}} -> name
      %{"pretty_name" => name} -> name
      _other -> nil
    end
  end

  # The picture of the map being played - with its time of day - and the
  # server's own art until the game state arrives.
  defp hero_art(%{"current_map" => map}, server) when is_map(map),
    do: MapArt.url(server.game, map)

  defp hero_art(_gamestate, server), do: HllConditionalActionsWeb.Ui.server_art(server)

  defp vip_count(roster) when is_map(roster) and map_size(roster) > 0 do
    players = Map.values(roster)

    if Enum.any?(players, &Map.has_key?(&1, "is_vip")),
      do: Enum.count(players, &(&1["is_vip"] == true))
  end

  defp vip_count(_roster), do: nil

  @helicopter_roles ~w(helicopterpilot helicopterlogisticsofficer)

  # The tile beside the VIPs: the queue, or on Vietnam the helicopters that
  # have a crew - squads of helicopter roles with somebody in them - as
  # {label, value}, or nil when there is nothing to show.
  defp side_tile(_queue, roster, game)
       when game in [:hllv, "hllv"] and is_map(roster) and map_size(roster) > 0 do
    crews =
      roster
      |> Map.values()
      |> Enum.filter(&(&1["role"] in @helicopter_roles))
      |> Enum.uniq_by(&{&1["team"], &1["unit_name"]})
      |> length()

    {gettext("Helicopters crewed"), crews}
  end

  defp side_tile(queue, _roster, _game) when is_integer(queue), do: {gettext("In queue"), queue}
  defp side_tile(_queue, _roster, _game), do: nil

  defp stream_text(:connected), do: "text-primary"
  defp stream_text(:connecting), do: "text-warning"
  defp stream_text({:error, _reason}), do: "text-error"
  defp stream_text(_status), do: "text-muted"

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: round(value)
  defp number(_value), do: 0

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(value) when is_float(value) and value > 0, do: round(value)
  defp positive(_value), do: nil
end
