defmodule HllConditionalActionsWeb.SeasonLive.Dashboard do
  @moduledoc """
  One season as the seasons page draws it (Seasons board): the photo hero
  with its progress, the podium, the standings with the prize line and the
  week's movement, how the score is made, and what happens when it closes.
  `SeasonLive.Index` shows the running season this way, `SeasonLive.Show`
  any season.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.CommunityComponents

  alias HllConditionalActions.Progression
  alias HllConditionalActions.Progression.Rating
  alias HllConditionalActions.Progression.Scoring
  alias HllConditionalActionsWeb.RatingComponents

  @rows 12

  @doc """
  Everything the dashboard needs of a season, read at once.
  """
  @spec data(map()) :: map()
  def data(season) do
    standings = Progression.standings(season, limit: 5000)
    qualified = Enum.filter(standings, & &1.qualified)
    winners = Enum.take(qualified, season.winners_count)

    %{
      season: season,
      standings: standings,
      winners: MapSet.new(winners, & &1.id),
      last_winner: List.last(winners),
      podium: Enum.take(qualified, 3),
      moves: Progression.rank_moves(season, standings),
      participants: Progression.season_participants(season),
      rating: Rating.normalize(season.rating)
    }
  end

  attr :data, :map, required: true
  attr :search, :string, default: ""
  attr :all?, :boolean, default: false
  attr :now, :any, required: true

  def dashboard(assigns) do
    ~H"""
    <div id="season-dashboard" class="flex flex-col gap-5">
      <div class="grid gap-5 xl:h-[21.25rem] xl:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <.hero data={@data} now={@now} />
        <.podium data={@data} />
      </div>

      <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_23.75rem]">
        <.standings data={@data} search={@search} all?={@all?} />
        <div class="flex min-w-0 flex-col gap-5">
          <.how_it_scores season={@data.season} />
          <.on_close season={@data.season} />
        </div>
      </div>
    </div>
    """
  end

  # ── Hero ───────────────────────────────────────────────────────────────────

  attr :data, :map, required: true
  attr :now, :any, required: true

  defp hero(assigns) do
    season = assigns.data.season
    total = max(season.duration_days, 1)

    day =
      assigns.now |> DateTime.diff(season.starts_at, :day) |> Kernel.+(1) |> max(1) |> min(total)

    assigns =
      assign(assigns,
        season: season,
        day: day,
        total: total,
        active?: season.status == :active,
        elapsed: elapsed(season, assigns.now)
      )

    ~H"""
    <section
      id="season-hero"
      class="season-hero relative min-h-[18rem] overflow-hidden rounded-[1.75rem]"
    >
      <img
        src={hero_art(List.first(@season.servers))}
        alt=""
        class="absolute inset-0 size-full object-cover opacity-50"
      />
      <div class="season-hero-scrim absolute inset-0"></div>
      <div class="relative flex h-full flex-col gap-2.5 px-6 py-6 sm:px-7 sm:py-[1.625rem]">
        <.pill :if={@active?} tone="live" class="self-start">{gettext("Running")}</.pill>
        <.pill :if={not @active?} tone="neutral" class="self-start bg-[#20211d] text-[#cfcfc6]">
          {gettext("Finished")}
        </.pill>
        <span class="min-h-8 flex-1"></span>
        <h2
          id="season-name"
          class="font-display text-4xl font-bold leading-none tracking-[-0.03em] sm:text-[2.75rem]"
        >
          {@season.name}
        </h2>
        <span class="text-[0.9375rem] text-[#cfcfc6]">
          {scoring_line(@season)} · {servers_line(@season.servers)}
        </span>
        <div class="mt-2 flex flex-col gap-2">
          <div class="flex justify-between gap-3 text-[0.8125rem]">
            <span class="text-[#cfcfc6]">
              {if @active?,
                do: gettext("Day %{day} of %{total}", day: @day, total: @total),
                else:
                  gettext("%{start} to %{end}",
                    start: short_date(DateTime.to_date(@season.starts_at)),
                    end: short_date(DateTime.to_date(@season.finished_at || @season.ends_at))
                  )}
            </span>
            <span :if={@active?} class="font-semibold text-[#d2f36b]">
              {ends_in(@season, @now)}
            </span>
          </div>
          <div class="flex h-2 rounded bg-white/12">
            <span
              class="rounded bg-[#d2f36b]"
              style={"width: #{if @active?, do: @elapsed, else: 100}%"}
            ></span>
          </div>
        </div>
        <div class="mt-2 flex flex-wrap gap-2.5">
          <span class="season-hero-chip rounded-full px-3 py-1.5 text-xs">
            {prize_chip(@season)}
          </span>
          <span
            :if={@season.min_matches > 0}
            class="season-hero-chip rounded-full px-3 py-1.5 text-xs"
          >
            {ngettext("At least 1 match", "At least %{count} matches", @season.min_matches)}
          </span>
          <span class="season-hero-chip rounded-full px-3 py-1.5 text-xs">
            {ngettext("1 participant", "%{count} participants", @data.participants)}
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp hero_art(nil), do: "/images/hll/banner.webp"
  defp hero_art(server), do: server_art(server)

  # ── Podium ─────────────────────────────────────────────────────────────────

  attr :data, :map, required: true

  defp podium(assigns) do
    podium = assigns.data.podium

    assigns =
      assign(assigns,
        second: Enum.at(podium, 1),
        first: Enum.at(podium, 0),
        third: Enum.at(podium, 2)
      )

    ~H"""
    <section
      id="season-podium"
      aria-label={gettext("Podium")}
      class="grid grid-cols-3 items-end gap-2.5 rounded-[1.75rem] bg-base-100 p-4 shadow-[var(--shadow-card)] sm:gap-3.5 sm:px-7 sm:py-6"
    >
      <.podium_step rank={2} score={@second} data={@data} class="h-44 sm:h-[14.375rem]" />
      <.podium_step rank={1} score={@first} data={@data} class="h-52 sm:h-[18.125rem]" />
      <.podium_step rank={3} score={@third} data={@data} class="h-40 sm:h-[12.5rem]" />
    </section>
    """
  end

  attr :rank, :integer, required: true
  attr :score, :any, required: true
  attr :data, :map, required: true
  attr :class, :any, default: nil

  defp podium_step(assigns) do
    ~H"""
    <div class={[
      "flex min-w-0 flex-col gap-1.5 rounded-[1.375rem] p-3 sm:gap-2 sm:p-[1.125rem]",
      if(@rank == 1, do: "podium-first", else: "bg-secondary"),
      @class
    ]}>
      <div class="flex items-start justify-between">
        <span class={[
          "font-display font-bold leading-none",
          case @rank do
            1 -> "text-5xl sm:text-7xl"
            2 -> "podium-silver text-4xl sm:text-[3.5rem]"
            _ -> "podium-bronze text-4xl sm:text-5xl"
          end
        ]}>
          {@rank}
        </span>
        <.icon :if={@rank == 1} name="hero-trophy" class="size-6 sm:size-8" />
      </div>
      <span class="flex-1"></span>
      <%= if @score do %>
        <.link
          navigate={~p"/players/#{@score.player_id}"}
          class={[
            "truncate hover:underline",
            if(@rank == 1,
              do: "text-base font-bold sm:text-[1.1875rem]",
              else: "text-sm font-semibold sm:text-[1.0625rem]"
            )
          ]}
        >
          {@score.player_name || @score.player_id}
        </.link>
        <span class={[
          "hidden text-xs sm:block",
          if(@rank == 1, do: "podium-first-meta", else: "text-muted")
        ]}>
          {podium_meta(@score, @data.moves)}
        </span>
        <span class={[
          "font-display font-bold",
          case @rank do
            1 -> "text-[1.375rem] sm:text-[1.875rem]"
            2 -> "text-lg font-semibold sm:text-[1.625rem]"
            _ -> "text-lg font-semibold sm:text-[1.5rem]"
          end
        ]}>
          {number(@score.score)}
        </span>
      <% else %>
        <span class={["text-sm", if(@rank == 1, do: "podium-first-meta", else: "text-muted")]}>
          {gettext("Nobody yet")}
        </span>
      <% end %>
    </div>
    """
  end

  defp podium_meta(score, moves) do
    [
      team_label(Progression.main_side(score)),
      ngettext("1 match", "%{count} matches", score.matches),
      moved_words(moves[score.player_id])
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp moved_words(n) when is_integer(n) and n > 0, do: gettext("up %{count}", count: n)
  defp moved_words(n) when is_integer(n) and n < 0, do: gettext("down %{count}", count: abs(n))
  defp moved_words(_same), do: nil

  # ── Standings ──────────────────────────────────────────────────────────────

  attr :data, :map, required: true
  attr :search, :string, required: true
  attr :all?, :boolean, required: true

  defp standings(assigns) do
    %{season: season, standings: standings, last_winner: last_winner} = assigns.data
    query = assigns.search |> String.trim() |> String.downcase()

    ranked = Enum.with_index(standings, 1)

    rows =
      if query == "",
        do: ranked,
        else:
          Enum.filter(ranked, fn {score, _rank} ->
            String.contains?(String.downcase(score.player_name || score.player_id), query)
          end)

    shown = if assigns.all? or query != "", do: rows, else: Enum.take(rows, @rows)

    assigns =
      assign(assigns,
        season: season,
        rows: shown,
        total: length(rows),
        line_after: last_winner && last_winner.id,
        gap_row: gap_row(standings, assigns.data.winners, last_winner),
        searching?: query != ""
      )

    ~H"""
    <section
      id="season-standings"
      class="flex min-w-0 flex-col rounded-[1.75rem] bg-base-100 px-4 py-5 shadow-[var(--shadow-card)] sm:px-[1.625rem] sm:py-[1.375rem]"
    >
      <div class="mb-3 flex flex-wrap items-center gap-3">
        <h2 class="flex-1 font-display text-[1.25rem] font-semibold">{gettext("Standings")}</h2>
        <form
          id="standings-search"
          phx-change="search_standings"
          phx-submit="search_standings"
          class="w-full sm:w-60"
        >
          <label class="flex h-10 items-center gap-2 rounded-full bg-secondary px-3.5 text-muted">
            <.icon name="hero-magnifying-glass" class="size-4" />
            <input
              type="text"
              name="q"
              value={@search}
              phx-debounce="200"
              aria-label={gettext("Search player")}
              placeholder={gettext("Find a player")}
              class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[0.8125rem] text-base-content outline-0 focus:ring-0"
            />
          </label>
        </form>
      </div>

      <p :if={@data.standings == []} class="py-10 text-center text-sm text-muted">
        {gettext("Nobody has scored yet: every match that ends on the server adds to the season.")}
      </p>

      <div :if={@data.standings != []} class="season-standings-grid px-2.5 py-2 text-xs text-muted">
        <span>#</span>
        <span>{gettext("Player")}</span>
        <span class="text-right">{gettext("Matches")}</span>
        <span class="hidden text-right md:block">{average_header(@season)}</span>
        <span class="text-right md:block">{points_header(@season)}</span>
        <span class="hidden text-right md:block">{gettext("Week")}</span>
      </div>

      <%= for {score, rank} <- @rows do %>
        <div
          id={"standing-#{score.id}"}
          class={[
            "season-standings-grid rounded-xl px-2.5 py-[0.6875rem] text-sm leading-[1.125rem]",
            @gap_row && @gap_row.id == score.id && !@searching? && "bg-secondary",
            not score.qualified && "text-muted"
          ]}
        >
          <span class={[
            "font-mono",
            if(MapSet.member?(@data.winners, score.id), do: "text-primary", else: "text-muted")
          ]}>
            {String.pad_leading(to_string(rank), 2, "0")}
          </span>
          <span class="min-w-0 truncate font-semibold">
            <.link navigate={~p"/players/#{score.player_id}"} class="hover:underline">
              {score.player_name || score.player_id}
            </.link>
            <span
              :if={@gap_row && @gap_row.id == score.id && @data.last_winner}
              class="text-xs font-normal text-warning"
            >
              · {gettext("%{points} pts from the podium",
                points: number(@data.last_winner.score - score.score)
              )}
            </span>
            <span :if={not score.qualified} class="text-xs font-normal">
              · {ngettext(
                "1 more match to count",
                "%{count} more matches to count",
                @season.min_matches - score.matches
              )}
            </span>
            <RatingComponents.tier_badge
              :if={@season.scoring == :elo and score.matches >= @data.rating["placement"]}
              tier={Rating.tier(score.score, @data.rating)}
            />
          </span>
          <span class="text-right font-mono text-subtle">{score.matches}</span>
          <span class="hidden text-right font-mono text-subtle md:block">
            {average_cell(@season, score)}
          </span>
          <span class="text-right font-mono">{number(score.score)}</span>
          <span class="hidden text-right md:block">
            <.delta moved={Map.get(@data.moves, score.player_id)} />
          </span>
        </div>
        <div
          :if={@line_after == score.id and not @searching?}
          id="prize-line"
          class="flex items-center gap-2.5 px-2.5 py-1"
        >
          <span class="prize-line"></span>
          <span class="text-[0.6875rem] font-semibold tracking-[0.06em] text-primary uppercase">
            {gettext("Prize line")}
          </span>
          <span class="prize-line"></span>
        </div>
      <% end %>

      <p :if={@searching? and @rows == []} class="py-6 text-center text-sm text-muted">
        {gettext("Nobody by that name in this season.")}
      </p>

      <div :if={not @searching? and length(@rows) < @total} class="flex items-center gap-3 pt-3">
        <span class="flex-1 text-[0.8125rem] text-muted">
          {gettext("%{shown} of %{total} players", shown: length(@rows), total: @total)}
        </span>
        <button
          id="standings-all"
          type="button"
          phx-click="standings_all"
          class="h-10 rounded-full border border-base-300 bg-secondary px-[1.125rem] text-[0.8125rem] transition-colors hover:bg-base-300"
        >
          {gettext("Show all")}
        </button>
      </div>
    </section>
    """
  end

  # The first player below the prize line, who is told how far the podium is.
  defp gap_row(_standings, _winners, nil), do: nil

  defp gap_row(standings, winners, _last) do
    Enum.find(standings, &(&1.qualified and not MapSet.member?(winners, &1.id)))
  end

  defp average_header(%{scoring: :elo}), do: gettext("W / L")
  defp average_header(%{scoring: :average}), do: gettext("Total")
  defp average_header(%{scoring: :weighted, per_match: true}), do: gettext("Total")
  defp average_header(_season), do: gettext("Average")

  defp points_header(%{scoring: :elo}), do: gettext("Rating")
  defp points_header(%{scoring: :average}), do: gettext("Average")
  defp points_header(%{scoring: :weighted, per_match: true}), do: gettext("Per match")
  defp points_header(_season), do: gettext("Points")

  defp average_cell(%{scoring: :elo}, score), do: "#{score.wins} / #{score.losses}"
  defp average_cell(%{scoring: :average}, score), do: number(score.total)
  defp average_cell(%{scoring: :weighted, per_match: true}, score), do: number(score.total)
  defp average_cell(_season, %{matches: 0}), do: "–"
  defp average_cell(_season, score), do: number(div(score.score, score.matches))

  # ── How the score is made ──────────────────────────────────────────────────

  attr :season, :map, required: true

  defp how_it_scores(assigns) do
    ~H"""
    <section
      id="season-formula"
      class="flex flex-col gap-3 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5 shadow-[var(--shadow-card)]"
    >
      <h2 class="font-display text-[1.25rem] font-semibold">{gettext("How the score is made")}</h2>
      <%= if @season.scoring == :elo do %>
        <RatingComponents.rating_summary config={@season.rating} />
      <% else %>
        <div class="rounded-2xl bg-secondary px-4 py-3.5 font-mono text-[0.8125rem] leading-[1.7]">
          <%= for {line, index} <- Enum.with_index(formula_lines(@season)) do %>
            <span class={["block", line.dim && "text-muted"]}>
              {if index > 0 and not line.dim, do: "+ "}{line.text}
            </span>
          <% end %>
        </div>
      <% end %>
      <span :if={@season.min_matches > 0} class="text-[0.8125rem] leading-normal text-subtle">
        {ngettext(
          "Whoever played fewer than 1 match shows up, but does not make the podium.",
          "Whoever played fewer than %{count} matches shows up, but does not make the podium.",
          @season.min_matches
        )}
      </span>
    </section>
    """
  end

  @doc "The lines of a season's formula: `%{text, dim}`."
  @spec formula_lines(map()) :: [map()]
  def formula_lines(%{scoring: :weighted} = season) do
    weighted = by_weight(season)

    if season.per_match,
      do: weighted ++ [%{text: "÷ " <> gettext("matches played"), dim: true}],
      else: weighted
  end

  def formula_lines(%{scoring: :average} = season),
    do: [
      %{text: metric_word(season.metric), dim: false},
      %{text: "÷ " <> gettext("matches played"), dim: true}
    ]

  def formula_lines(season),
    do: [
      %{text: metric_word(season.metric), dim: false},
      %{text: gettext("added up match after match"), dim: true}
    ]

  defp by_weight(season) do
    Scoring.weighted_metrics()
    |> Enum.map(&{&1, Scoring.weight(season.weights, &1)})
    |> Enum.reject(fn {_metric, weight} -> weight == 0 end)
    |> Enum.sort_by(fn {_metric, weight} -> -weight end)
    |> Enum.map(fn {metric, weight} ->
      %{text: "#{metric_word(metric)} × #{weight_text(weight)}", dim: false}
    end)
  end

  @doc "A stat in a formula, lowercase: \"combate\"."
  @spec metric_word(atom() | nil) :: String.t()
  def metric_word(nil), do: "–"

  def metric_word(metric) do
    label =
      if metric in HllConditionalActions.Leaderboards.categories(),
        do: Labels.leaderboard_category(metric),
        else: Labels.metric(metric)

    String.downcase(label)
  end

  @doc ~s(A weight with one decimal at least, in the viewer's mark: "1,0", "0,6".)
  @spec weight_text(number()) :: String.t()
  def weight_text(weight) when is_integer(weight), do: decimal(weight, 1)

  def weight_text(weight) do
    if Float.round(weight, 1) == weight, do: decimal(weight, 1), else: decimal(weight, 2)
  end

  # ── On close ───────────────────────────────────────────────────────────────

  attr :season, :map, required: true

  defp on_close(assigns) do
    ~H"""
    <section
      id="season-on-close"
      class="flex flex-col gap-2.5 rounded-[1.75rem] bg-base-100 px-[1.375rem] py-5 shadow-[var(--shadow-card)]"
    >
      <h2 class="mb-1 font-display text-[1.25rem] font-semibold">
        {if @season.status == :active, do: gettext("When it closes"), else: gettext("When it closed")}
      </h2>
      <div class="flex items-center gap-3 rounded-[0.875rem] bg-secondary px-3 py-2.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-[0.625rem] bg-accent/13 text-xs font-bold text-accent">
          VIP
        </span>
        <span class="text-sm">
          {if @season.reward_vip_hours > 0,
            do:
              ngettext(
                "%{vip} of VIP for the top 1",
                "%{vip} of VIP for the top %{count}",
                @season.winners_count,
                vip: vip_words(@season.reward_vip_hours)
              ),
            else: gettext("No VIP: the winners are only announced")}
        </span>
      </div>
      <div class="flex items-center gap-3 rounded-[0.875rem] bg-secondary px-3 py-2.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-[0.625rem] bg-primary/12 text-primary">
          <.icon name="hero-chat-bubble-bottom-center" class="size-4" />
        </span>
        <span class="text-sm">{gettext("Announce the winners in game")}</span>
      </div>
      <div class="flex items-center gap-3 rounded-[0.875rem] bg-secondary px-3 py-2.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-[0.625rem] bg-base-300 text-subtle">
          <.icon name="hero-arrow-path" class="size-4" />
        </span>
        <span class="text-sm">
          {if @season.auto_renew,
            do: gettext("Open the next season on its own"),
            else: gettext("Does not open the next season")}
        </span>
      </div>
    </section>
    """
  end

  # ── Words ──────────────────────────────────────────────────────────────────

  @doc ~s("Weighted score by combat", "Sum of kills"...)
  @spec scoring_line(map()) :: String.t()
  def scoring_line(%{scoring: :weighted} = season) do
    top =
      Scoring.weighted_metrics()
      |> Enum.max_by(&Scoring.weight(season.weights, &1), fn -> nil end)

    if season.per_match,
      do: gettext("Weighted score per match, led by %{metric}", metric: metric_word(top)),
      else: gettext("Weighted score, led by %{metric}", metric: metric_word(top))
  end

  def scoring_line(%{scoring: :average} = season),
    do: gettext("Average of %{metric} per match", metric: metric_word(season.metric))

  def scoring_line(%{scoring: :elo}), do: gettext("Elo rating")

  def scoring_line(season), do: gettext("Sum of %{metric}", metric: metric_word(season.metric))

  @doc "\"BR #1 e BR #2\"."
  @spec servers_line([map()]) :: String.t()
  def servers_line([]), do: "–"
  def servers_line([one]), do: one.name

  def servers_line(servers) do
    {rest, [last]} = Enum.split(Enum.map(servers, & &1.name), -1)
    gettext("%{list} and %{last}", list: Enum.join(rest, ", "), last: last)
  end

  defp prize_chip(%{reward_vip_hours: 0} = season),
    do: ngettext("Top 1 is announced", "Top %{count} are announced", season.winners_count)

  defp prize_chip(season),
    do:
      ngettext("Top 1 wins %{vip} of VIP", "Top %{count} win %{vip} of VIP", season.winners_count,
        vip: vip_words(season.reward_vip_hours)
      )

  @doc ~s("30 dias", "12 h".)
  @spec vip_words(integer()) :: String.t()
  def vip_words(hours) when rem(hours, 24) == 0,
    do: ngettext("1 day", "%{count} days", div(hours, 24))

  def vip_words(hours), do: ngettext("1 hour", "%{count} hours", hours)

  @doc "\"ends in 18 days\"."
  @spec ends_in(map(), DateTime.t()) :: String.t()
  def ends_in(season, now) do
    case DateTime.diff(season.ends_at, now, :hour) do
      hours when hours <= 0 -> gettext("closing")
      hours when hours < 48 -> ngettext("ends in 1 hour", "ends in %{count} hours", hours)
      hours -> ngettext("ends in 1 day", "ends in %{count} days", div(hours, 24))
    end
  end

  @doc "How much of the season has gone, in percent."
  @spec elapsed(map(), DateTime.t()) :: integer()
  def elapsed(season, now) do
    total = max(DateTime.diff(season.ends_at, season.starts_at), 1)
    (DateTime.diff(now, season.starts_at) * 100 / total) |> max(0) |> min(100) |> round()
  end
end
