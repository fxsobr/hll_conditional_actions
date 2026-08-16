defmodule HllConditionalActions.Engine.Template do
  @moduledoc """
  `{placeholder}` substitution for the text an action sends in game.

  The syntax matches CRCON's own message templates, so a message written in the
  CRCON UI can be pasted here unchanged:

      "Welcome {player_name}! You are level {player_level}."

  Unknown placeholders are left as written rather than blanked out, which makes
  a typo visible in game instead of silently producing "Welcome !".
  """

  alias HllConditionalActions.Engine.Context

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
  @spec render(String.t() | nil, Context.t() | %{String.t() => String.t()}) :: String.t()
  def render(nil, _variables), do: ""

  def render(template, %Context{} = context), do: render(template, Context.variables(context))

  def render(template, variables) when is_binary(template) and is_map(variables) do
    Regex.replace(@placeholder, template, fn full_match, name ->
      Map.get(variables, name, full_match)
    end)
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
      playtime_minutes map_name game_mode server_name server_player_count
      weapon target_player_name message
    )
  end
end
