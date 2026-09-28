defmodule HllConditionalActionsWeb.RecipeText do
  @moduledoc """
  The words a recipe puts into a rule - the messages players read in game,
  VIP descriptions, watchlist reasons - in the language of the admin who
  opens the recipe.

  `HllConditionalActions.Rules.Recipes` keeps them in English, as data; the
  builder passes each through `translate/1` when it fills the form, so a
  Brazilian community starts with Portuguese messages and can still edit
  them. Every text is listed below with `dgettext_noop/2` so
  `mix gettext.extract` finds it; placeholders like `{player_name}` stay
  as they are in every language.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  @keys ~w(message description reason comment)

  @doc """
  A recipe's attributes with its action texts translated.
  """
  @spec translate_attrs(map()) :: map()
  def translate_attrs(%{actions: actions} = attrs) when is_list(actions) do
    %{attrs | actions: Enum.map(actions, &translate_action/1)}
  end

  def translate_attrs(attrs), do: attrs

  defp translate_action(%{parameters: parameters} = action) when is_map(parameters) do
    %{
      action
      | parameters:
          Map.new(parameters, fn
            {key, value} when key in @keys and is_binary(value) -> {key, translate(value)}
            other -> other
          end)
    }
  end

  defp translate_action(action), do: action

  @doc "One recipe text in the current locale, or as written when unknown."
  @spec translate(String.t()) :: String.t()
  def translate(text), do: Gettext.dgettext(HllConditionalActionsWeb.Gettext, "recipes", text)

  @doc false
  def texts do
    [
      dgettext_noop("recipes", "Best squad of the match"),
      dgettext_noop("recipes", "Join us at discord.gg/your-invite"),
      dgettext_noop(
        "recipes",
        "MATCH TOP\nKills: {top_kills}\nSupport: {top_support}\nDefense: {top_defense}\nBest squads: {top_infantry_squads}"
      ),
      dgettext_noop("recipes", "MVP of the match"),
      dgettext_noop("recipes", "Melee kill! You got {target_player_name} with your {weapon}."),
      dgettext_noop("recipes", "Repeated team killing"),
      dgettext_noop("recipes", "Seeding reward"),
      dgettext_noop("recipes", "Solo tanking"),
      dgettext_noop("recipes", "Squad without an officer"),
      dgettext_noop("recipes", "Still no officer in your squad. Next time this costs you."),
      dgettext_noop(
        "recipes",
        "TOP PLAYERS\nKills: {top_kills}\nTeamplay: {top_teamplay}\nOffense + defense: {top_offdef}\n\nTOP SQUADS\nInfantry: {top_infantry_squads}\nArmor: {top_armor_squads}"
      ),
      dgettext_noop("recipes", "Team killing"),
      dgettext_noop("recipes", "Thanks for commanding this match! You have VIP for 24 hours."),
      dgettext_noop("recipes", "Thanks for commanding"),
      dgettext_noop("recipes", "Thanks for helping us seed! You have VIP for 24 hours."),
      dgettext_noop("recipes", "Thanks for leading a squad"),
      dgettext_noop(
        "recipes",
        "Thanks for leading your squad this match! You have VIP for 12 hours."
      ),
      dgettext_noop("recipes", "Top support of the match"),
      dgettext_noop("recipes", "Very low level, joined recently"),
      dgettext_noop("recipes", "Watch your fire, {player_name}. That was a team mate."),
      dgettext_noop("recipes", "Welcome {player_name}! Have a good match."),
      dgettext_noop("recipes", "Welcome! Ask your squad for help, everyone starts somewhere."),
      dgettext_noop("recipes", "You are alone in an armor squad. Crew up or switch role."),
      dgettext_noop("recipes", "You were the MVP of this match! You have VIP for 24 hours."),
      dgettext_noop(
        "recipes",
        "You were the best supporter of this match! You have VIP for 24 hours."
      ),
      dgettext_noop("recipes", "Your achievements ({achievements_count}):\n{achievements}"),
      dgettext_noop("recipes", "Your position this season: {season_rank}\nTop: {season_top}"),
      dgettext_noop("recipes", "Your squad has no officer. Take the role or join another squad."),
      dgettext_noop("recipes", "Your squad was the best of the match! You have VIP for 12 hours.")
    ]
  end
end
