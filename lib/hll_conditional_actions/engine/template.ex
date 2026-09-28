defmodule HllConditionalActions.Engine.Template do
  @moduledoc """
  `{placeholder}` substitution for the text an action sends in game.

  The syntax matches CRCON's own message templates, so a message written in the
  CRCON UI can be pasted here unchanged:

      "Welcome {player_name}! You are level {player_level}."

  Unknown placeholders are left as written rather than blanked out, which makes
  a typo visible in game instead of silently producing "Welcome !".

  The `:escape` option runs every substituted value through a function - the
  Discord action uses it so a player's name cannot inject markdown, while the
  rule author's own markdown around the placeholders still works.
  """

  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Leaderboards
  alias HllConditionalActions.Progression

  @placeholder ~r/\{([a-z_][a-z0-9_]*)\}/

  @doc """
  Renders a template against a context or an explicit variable map.

      iex> alias HllConditionalActions.Engine.{Context, Template}
      iex> server = %HllConditionalActions.Servers.Server{id: 1, name: "EU #1", game: :hll}
      iex> context = Context.build(server, :player_connected, player_name: "Chris")
      iex> Template.render("Welcome {player_name} to {server_name}!", context)
      "Welcome Chris to EU #1!"

      iex> HllConditionalActions.Engine.Template.render("Hi {name}, bye {nope}", %{"name" => "Ana"})
      "Hi Ana, bye {nope}"
  """
  @spec render(String.t() | nil, Context.t() | %{String.t() => String.t()}, keyword()) ::
          String.t()
  def render(template, variables, opts \\ [])

  def render(nil, _variables, _opts), do: ""

  def render(template, %Context{} = context, opts) when is_binary(template) do
    variables =
      template
      |> placeholders()
      |> Enum.reduce(Context.variables(context), fn name, acc ->
        case computed(name, context) do
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      end)

    render(template, variables, opts)
  end

  def render(template, variables, opts) when is_binary(template) and is_map(variables) do
    escape = Keyword.get(opts, :escape, & &1)

    Regex.replace(@placeholder, template, fn full_match, name ->
      case Map.fetch(variables, name) do
        {:ok, value} when is_binary(value) -> escape.(value)
        {:ok, value} -> value
        :error -> full_match
      end
    end)
  end

  # `{top_kills}`, `{top_support}` ... and `{top_armor_squads}` ...: the top
  # three of a category as one language free line, only computed when a
  # message actually asks for one.
  @leaderboard_placeholders Map.new(
                              Leaderboards.categories(),
                              &{"top_#{&1}", {:players, &1}}
                            )
                            |> Map.merge(
                              Map.new(
                                Leaderboards.squad_types(),
                                &{"top_#{&1}_squads", {:squads, &1}}
                              )
                            )

  @leaderboard_size 3

  @progression_placeholders ~w(achievements achievements_count season_rank season_top)

  @doc "The achievement and season placeholders, for the builder's help text."
  @spec progression_placeholders() :: [String.t()]
  def progression_placeholders, do: @progression_placeholders

  # Placeholders that cost a computation or a query, filled only when the
  # message uses them.
  defp computed("top_" <> _rest = name, context), do: leaderboard(name, context.roster)

  defp computed(name, context) when name in @progression_placeholders do
    progression(name, context)
  end

  defp computed(_name, _context), do: nil

  defp progression("achievements", context) do
    context
    |> player_unlocks()
    |> Enum.map_join(
      ", ",
      &"#{Progression.game_mark(&1.achievement.tier)} #{&1.achievement.name}"
    )
    |> dash_if_blank()
  end

  defp progression("achievements_count", context) do
    context |> player_unlocks() |> length() |> to_string()
  end

  defp progression("season_rank", context) do
    case Progression.season_rank(context.server.id, context.player_id) do
      {_season, rank, score} -> "##{rank} (#{score})"
      nil -> "-"
    end
  end

  defp progression("season_top", context) do
    Progression.season_line(context.server.id) || "-"
  end

  defp player_unlocks(%{player_id: nil}), do: []

  defp player_unlocks(context) do
    context.player_id
    |> Progression.player_achievements(context.server.id)
    |> Enum.reject(& &1.simulated)
  end

  defp dash_if_blank(""), do: "-"
  defp dash_if_blank(text), do: text

  defp leaderboard(name, roster) do
    case Map.get(@leaderboard_placeholders, name) do
      {:players, category} -> Leaderboards.line(roster, category, @leaderboard_size)
      {:squads, type} -> Leaderboards.squad_line(roster, type, @leaderboard_size)
      nil -> nil
    end
  end

  @doc """
  The leaderboard placeholders, for the builder's help text.
  """
  @spec leaderboard_placeholders() :: [String.t()]
  def leaderboard_placeholders do
    Enum.map(Leaderboards.categories(), &"top_#{&1}") ++
      Enum.map(Leaderboards.squad_types(), &"top_#{&1}_squads")
  end

  @doc """
  The placeholders a template uses.

      iex> HllConditionalActions.Engine.Template.placeholders("{player_name} killed {target_player_name}")
      ["player_name", "target_player_name"]
  """
  @spec placeholders(String.t() | nil) :: [String.t()]
  def placeholders(nil), do: []

  def placeholders(template) when is_binary(template) do
    @placeholder
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Every placeholder the engine knows how to fill, for the builder's help text.
  """
  @spec known_placeholders() :: [String.t()]
  def known_placeholders do
    ~w(
      player_name player_id player_level player_role team unit_name clan_tag
      kills deaths teamkills combat offense defense support is_vip
      vehicles_destroyed playtime_minutes map_name game_mode server_name server_player_count
      team_objectives enemy_objectives
      weapon target_player_name message
    )
  end

  # Placeholders filled only by the event that carries them; everywhere else
  # they would render empty.
  @event_placeholders %{
    "weapon" => [:player_kill, :player_death, :player_team_kill],
    "target_player_name" => [:player_kill, :player_death, :player_team_kill],
    "message" => [:player_chat, :chat_command]
  }

  @doc """
  The simple placeholders a trigger fills, for the builder's `{` menu.

      iex> alias HllConditionalActions.Engine.Template
      iex> {"weapon" in Template.placeholders_for(:player_kill), "weapon" in Template.placeholders_for(:player_connected)}
      {true, false}
  """
  @spec placeholders_for(atom()) :: [String.t()]
  def placeholders_for(trigger) do
    Enum.filter(known_placeholders(), fn name ->
      case Map.fetch(@event_placeholders, name) do
        {:ok, triggers} -> trigger in triggers
        :error -> true
      end
    end)
  end

  @doc """
  Every placeholder a message may use under a trigger, computed ones included.
  """
  @spec valid_placeholders(atom()) :: [String.t()]
  def valid_placeholders(trigger) do
    placeholders_for(trigger) ++ leaderboard_placeholders() ++ progression_placeholders()
  end

  @doc """
  The placeholders of a template that a trigger cannot fill.

      iex> HllConditionalActions.Engine.Template.unknown_placeholders("Hi {player_name} {nope}", :player_connected)
      ["nope"]
  """
  @spec unknown_placeholders(String.t() | nil, atom()) :: [String.t()]
  def unknown_placeholders(template, trigger) when is_binary(template) do
    template |> placeholders() |> Enum.reject(&(&1 in valid_placeholders(trigger)))
  end

  def unknown_placeholders(_template, _trigger), do: []
end
