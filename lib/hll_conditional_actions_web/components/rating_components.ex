defmodule HllConditionalActionsWeb.RatingComponents do
  @moduledoc """
  The rating of an Elo season on screen: the builder where an admin puts
  the formula together (presets first, every block tunable after), what the
  formula does to a few typical players while it is being built, and the
  tier badges of the standings.

  The math is `HllConditionalActions.Progression.Rating`; this module only
  shows it.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Progression.Rating

  # ── Builder ────────────────────────────────────────────────────────────────

  @doc """
  Every setting of the rating, as inputs named `<name>[key]`, and beside them
  what the formula does. `config` is the normalized configuration.
  """
  attr :name, :string, required: true
  attr :config, :map, required: true

  def rating_builder(assigns) do
    assigns =
      assign(assigns,
        weight: assigns.config["result_weight"]
      )

    ~H"""
    <div id="rating-builder">
      <div class="min-w-0 space-y-4">
        <input type="hidden" name={"#{@name}[preset]"} value={@config["preset"]} />

        <div class="rating-block">
          <p class="rating-block-title">
            <span class="rating-step">1</span>{gettext("Result or performance")}
          </p>
          <div class="grid gap-4">
            <.choice
              name={"#{@name}[result]"}
              value={@config["result"]}
              label={gettext("A match's result is")}
              options={[
                {"win", gettext("Win or loss")},
                {"caps", gettext("Sectors held")}
              ]}
            />
            <label class="block">
              <span class="rating-label">{gettext("Weight of the result")}</span>
              <input
                type="range"
                min="0"
                max="100"
                step="5"
                name={"#{@name}[result_weight]"}
                value={@weight}
                class="rating-range"
                aria-valuetext={"#{@weight}%"}
              />
              <span class="flex justify-between text-xs text-muted">
                <span>{gettext("%{percent}% result", percent: @weight)}</span>
                <span>{gettext("%{percent}% performance", percent: 100 - @weight)}</span>
              </span>
            </label>
          </div>
          <p class="rating-hint">
            {if @config["result"] == "caps",
              do:
                gettext(
                  "Sectors held at the end out of five, like the HeLO clan ranking: a 4-1 loss costs less than a 0-5."
                ),
              else: gettext("1 for a win, 0.5 for a draw, 0 for a loss, like FACEIT.")}
          </p>
        </div>

        <div :if={@weight < 100} class="rating-block" id="rating-performance">
          <p class="rating-block-title">
            <span class="rating-step">2</span>{gettext("What performance means")}
          </p>
          <p class="rating-hint -mt-1 mb-2">
            {gettext(
              "Each stat is ranked inside the player's own team, so a map full of kills inflates nobody. Zero leaves a stat out."
            )}
          </p>
          <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
            <label :for={stat <- Rating.perf_stats()} class="weight-field">
              <span class="truncate text-xs text-subtle">{stat_label(stat)}</span>
              <input
                type="number"
                min="0"
                max="100"
                name={"#{@name}[performance][#{stat}]"}
                value={@config["performance"][stat]}
                class="pc-text-input w-16 text-center"
              />
            </label>
          </div>
          <label class="weight-field mt-2 max-w-xs">
            <span class="text-xs text-subtle">{gettext("Penalty per teamkill (%)")}</span>
            <input
              type="number"
              min="0"
              max="50"
              name={"#{@name}[teamkill_penalty]"}
              value={@config["teamkill_penalty"]}
              class="pc-text-input w-16 text-center"
            />
          </label>
        </div>

        <div class="rating-block">
          <p class="rating-block-title">
            <span class="rating-step">{if @weight < 100, do: 3, else: 2}</span>{gettext(
              "How fast it moves"
            )}
          </p>
          <div class="grid gap-3 sm:grid-cols-3">
            <.number_field
              name={"#{@name}[k]"}
              value={@config["k"]}
              label={gettext("K factor")}
              max={100}
            />
            <.choice
              name={"#{@name}[k_mode]"}
              value={@config["k_mode"]}
              label={gettext("K over time")}
              options={[{"fixed", gettext("Fixed")}, {"decreasing", gettext("Settles")}]}
            />
            <.number_field
              name={"#{@name}[placement]"}
              value={@config["placement"]}
              label={gettext("Placement matches")}
              max={50}
            />
          </div>
          <p class="rating-hint">
            {if @config["k_mode"] == "decreasing",
              do:
                gettext(
                  "Starts at twice K and settles towards half of it as a player plays, so newcomers find their level fast. Placement matches count double."
                ),
              else: gettext("The same K for everybody. Placement matches count double.")}
          </p>
        </div>

        <div class="rating-block">
          <p class="rating-block-title">
            <span class="rating-step">{if @weight < 100, do: 4, else: 3}</span>{gettext("Limits")}
          </p>
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <.number_field
              name={"#{@name}[initial]"}
              value={@config["initial"]}
              label={gettext("Starting rating")}
              unit="pts"
              max={5000}
            />
            <.number_field
              name={"#{@name}[floor]"}
              value={@config["floor"]}
              label={gettext("Lowest rating")}
              unit="pts"
              max={5000}
            />
            <.number_field
              name={"#{@name}[max_change]"}
              value={@config["max_change"]}
              label={gettext("Most per match")}
              unit="pts"
              max={500}
            />
            <.number_field
              name={"#{@name}[min_minutes]"}
              value={@config["min_minutes"]}
              label={gettext("Least time played")}
              unit="min"
              max={120}
            />
            <.number_field
              name={"#{@name}[decay]"}
              value={@config["decay"]}
              label={gettext("Idle decay")}
              unit={gettext("%/week")}
              max={50}
            />
          </div>
          <p class="rating-hint">
            {gettext(
              "Decay pulls a rating back towards the start after two weeks without playing, so nobody holds the top by staying away."
            )}
          </p>
          <div class="mt-3 grid gap-2">
            <.toggle
              name={"#{@name}[no_gain_on_loss]"}
              checked={@config["no_gain_on_loss"]}
              label={gettext("A loss never raises a rating, a win never lowers it")}
            />
            <.toggle
              name={"#{@name}[time_scaled]"}
              checked={@config["time_scaled"]}
              label={gettext("Scale by the share of the match played")}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true

  defp choice(assigns) do
    ~H"""
    <div>
      <span class="rating-label">{@label}</span>
      <div class="segmented" role="radiogroup" aria-label={@label}>
        <label :for={{value, text} <- @options} class="segmented-option">
          <input type="radio" name={@name} value={value} checked={@value == value} class="sr-only" />
          <span>{text}</span>
        </label>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :max, :integer, required: true
  attr :unit, :string, default: nil

  defp number_field(assigns) do
    ~H"""
    <label class="block min-w-0">
      <span class="rating-label truncate" title={@label}>{@label}</span>
      <span class="unit-input">
        <input type="number" min="0" max={@max} name={@name} value={@value} />
        <span :if={@unit} class="unit-input-suffix">{@unit}</span>
      </span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true

  defp toggle(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-center gap-2 text-sm">
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" name={@name} value="true" checked={@checked} class="pc-checkbox" />
      <span>{@label}</span>
    </label>
    """
  end

  # ── What it does ───────────────────────────────────────────────────────────

  @doc """
  The formula with the season's numbers in it, and what it gives a few
  typical players of an even match - so the settings are never a guess.
  """
  attr :config, :map, required: true

  def rating_preview(assigns) do
    config = assigns.config
    weight = config["result_weight"]

    rows = preview_rows(config)

    scale =
      rows |> Enum.flat_map(fn {_label, win, loss} -> [abs(win), abs(loss)] end) |> Enum.max()

    assigns =
      assign(assigns,
        k: round(Rating.k(config, 30)),
        result_part: format(weight / 100),
        performance_part: format((100 - weight) / 100),
        rows: rows,
        scale: max(scale, 1)
      )

    ~H"""
    <div id="rating-preview" class="rating-preview">
      <p class="text-xs font-semibold tracking-wide text-muted uppercase">
        {gettext("Live preview")}
      </p>

      <p class="rating-formula">
        <span class="text-muted">Δ =</span>
        <span class="rating-formula-k">{@k}</span>
        <span class="text-muted">× (</span>
        <span class="text-primary">{@result_part}</span>
        <span>× {gettext("result")}</span>
        <span class="text-muted">+</span>
        <span class="text-primary">{@performance_part}</span>
        <span>× {gettext("performance")}</span>
        <span class="text-muted">)</span>
      </p>
      <p class="mt-1 text-[0.6875rem] text-muted">
        {gettext("K of a player with 30 matches, in an even match.")}
      </p>

      <div class="mt-4 flex justify-between text-[0.6875rem] font-medium text-muted">
        <span>{gettext("Loss")}</span>
        <span>{gettext("Win")}</span>
      </div>
      <ul class="mt-1 space-y-2.5">
        <li :for={{label, win, loss} <- @rows}>
          <p class="mb-1 text-xs">{label}</p>
          <div class="delta-row">
            <span class="delta-value text-error">{signed(loss)}</span>
            <div class="delta-track">
              <span class="delta-bar delta-bar-loss" style={"width: #{bar(loss, @scale)}%"}></span>
            </div>
            <div class="delta-track">
              <span class="delta-bar delta-bar-win" style={"width: #{bar(win, @scale)}%"}></span>
            </div>
            <span class="delta-value text-right text-success">{signed(win)}</span>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp bar(value, scale), do: round(abs(value) * 100 / scale)

  defp preview_rows(config) do
    # A win in "caps" mode is taken as 4-1, a loss as 1-4.
    {win, loss} = if config["result"] == "caps", do: {0.8, 0.2}, else: {1.0, 0.0}

    for {label, performance} <- [
          {gettext("Best of the team"), 0.45},
          {gettext("Middle of the team"), 0.0},
          {gettext("Worst of the team"), -0.45}
        ] do
      row(config, label, performance, 30, win, loss)
    end ++
      [row(config, gettext("Newcomer, in placement"), 0.0, 0, win, loss)]
  end

  defp row(config, label, performance, matches, win, loss) do
    match = %{gap: 0, performance: performance, matches: matches, share: 1.0}

    {label, Rating.change(config, Map.merge(match, %{result: win, won: true})),
     Rating.change(config, Map.merge(match, %{result: loss, won: false}))}
  end

  @doc "The formula of a season, in a few lines, for its standings page."
  attr :config, :map, required: true

  def rating_summary(assigns) do
    assigns = assign(assigns, :config, Rating.normalize(assigns.config))

    ~H"""
    <div id="rating-summary" class="space-y-3 text-sm">
      <p class="text-subtle">
        {preset_label(@config["preset"])} · {gettext("%{percent}% result",
          percent: @config["result_weight"]
        )} · {gettext("%{percent}% performance", percent: 100 - @config["result_weight"])} · K {@config[
          "k"
        ]}
      </p>
      <.rating_preview config={@config} />
      <div>
        <p class="text-xs font-medium tracking-wide text-muted uppercase">{gettext("Tiers")}</p>
        <ul class="mt-2 flex flex-wrap gap-1.5">
          <li :for={{tier, from} <- Rating.tiers(@config)}>
            <.tier_badge tier={tier} />
            <span class="ml-1 font-mono text-xs text-muted">{from || "–"}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc "A rating tier as a small colored badge."
  attr :tier, :atom, required: true

  def tier_badge(assigns) do
    ~H"""
    <span class={["rating-tier", "rating-tier-#{@tier}"]}>{tier_label(@tier)}</span>
    """
  end

  @doc "The label of a rating tier."
  @spec tier_label(atom()) :: String.t()
  def tier_label(:bronze), do: gettext("Bronze")
  def tier_label(:silver), do: gettext("Silver")
  def tier_label(:gold), do: gettext("Gold")
  def tier_label(:platinum), do: gettext("Platinum")
  def tier_label(:diamond), do: gettext("Diamond")
  def tier_label(:master), do: gettext("Master")
  def tier_label(:legend), do: gettext("Legend")

  defp preset_label("competitive"), do: gettext("Competitive")
  defp preset_label("balanced"), do: gettext("Balanced")
  defp preset_label("performance"), do: gettext("Performance")
  defp preset_label(_custom), do: gettext("Custom")

  defp stat_label("combat"), do: gettext("Combat")
  defp stat_label("offense"), do: gettext("Offense")
  defp stat_label("defense"), do: gettext("Defense")
  defp stat_label("support"), do: gettext("Support")
  defp stat_label("kpm"), do: gettext("Kills per minute")
  defp stat_label("kd"), do: gettext("K/D")

  defp signed(0), do: "0"
  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: to_string(value)

  defp format(number) do
    number
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
    |> then(fn text ->
      if Gettext.get_locale(HllConditionalActionsWeb.Gettext) in ["pt_BR", "es"],
        do: String.replace(text, ".", ","),
        else: text
    end)
  end
end
