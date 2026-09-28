defmodule HllConditionalActionsWeb.RecipeArt do
  @moduledoc """
  A drawing for each recipe, in place of a generic icon: what the recipe is
  about, in the game's own terms - a helmet, rank chevrons, a tank, a knife,
  a flag on a sector.

  All share one style so the gallery reads as a set: a 48 unit square, a
  2 unit stroke in `currentColor` with round joins, and soft fills of the
  same colour at low opacity. The colour comes from the recipe's tone, set
  by the caller's text colour, so the drawings follow light and dark themes.
  """

  use Phoenix.Component

  attr :id, :atom, required: true
  attr :class, :any, default: "size-10"

  def recipe_art(assigns) do
    ~H"""
    <svg
      viewBox="0 0 48 48"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <.drawing id={@id} />
    </svg>
    """
  end

  attr :id, :atom, required: true

  # A soldier's helmet with a waving hand: somebody arriving.
  defp drawing(%{id: :welcome} = assigns) do
    ~H"""
    <path d="M8 30c0-9 6.5-15 15-15s15 6 15 15" fill="currentColor" fill-opacity=".14" />
    <path d="M5 30h36" />
    <path d="M14 30v4a9 9 0 0 0 18 0v-4" />
    <path d="M36 9l3-3m2 7h4m-6-3 4-2" />
    """
  end

  # Three privates and an empty place where the officer should be.
  defp drawing(%{id: :no_squad_leader} = assigns) do
    ~H"""
    <circle cx="12" cy="20" r="4" fill="currentColor" fill-opacity=".14" />
    <circle cx="24" cy="20" r="4" fill="currentColor" fill-opacity=".14" />
    <circle cx="36" cy="20" r="4" stroke-dasharray="3 3" />
    <path d="M5 36c0-5 3-8 7-8s7 3 7 8M17 36c0-5 3-8 7-8s7 3 7 8" />
    <path d="M30 36c0-5 3-8 6-8s6 3 6 8" stroke-dasharray="3 3" />
    <path d="M33 8l3 3 3-3" />
    """
  end

  # A tank with one crewman where there should be two.
  defp drawing(%{id: :solo_tank} = assigns) do
    ~H"""
    <path d="M8 26h32l-3 8H11z" fill="currentColor" fill-opacity=".14" />
    <path d="M15 26v-6h14v6M29 22h12" />
    <circle cx="14" cy="34" r="2" /><circle cx="24" cy="34" r="2" /><circle cx="34" cy="34" r="2" />
    <circle cx="22" cy="12" r="3" />
    <path d="M40 8v8m-4-4h8" transform="rotate(45 40 12)" />
    """
  end

  # Rank chevrons stacking up: each offence climbs a rung.
  defp drawing(%{id: :team_kill_ladder} = assigns) do
    ~H"""
    <path d="M12 34l12-6 12 6" />
    <path d="M12 26l12-6 12 6" />
    <path d="M12 18l12-6 12 6" fill="currentColor" fill-opacity=".14" />
    <path d="M24 38v4" />
    """
  end

  # A seedling on a nearly empty server bar.
  defp drawing(%{id: :seeding_reward} = assigns) do
    ~H"""
    <rect x="6" y="34" width="36" height="6" rx="3" />
    <rect x="6" y="34" width="10" height="6" rx="3" fill="currentColor" fill-opacity=".3" />
    <path d="M24 34V18" />
    <path
      d="M24 24c-6 0-9-4-9-9 6 0 9 4 9 9zM24 20c0-6 3-9 9-9 0 6-3 9-9 9z"
      fill="currentColor"
      fill-opacity=".14"
    />
    """
  end

  # A chat bubble carrying "!".
  defp drawing(%{id: id} = assigns)
       when id in [:chat_command_discord, :achievements_command, :season_command] do
    ~H"""
    <path
      d="M8 12a4 4 0 0 1 4-4h24a4 4 0 0 1 4 4v14a4 4 0 0 1-4 4H20l-8 7v-7a4 4 0 0 1-4-4z"
      fill="currentColor"
      fill-opacity=".14"
    />
    <path d="M24 13v7" /><circle cx="24" cy="24.5" r=".5" fill="currentColor" />
    <path :if={@id == :achievements_command} d="M34 34l3 3 6-6" />
    <path :if={@id == :season_command} d="M32 34h10v8H32zM35 32v3m4-3v3" />
    """
  end

  # Field glasses: keeping an eye on someone new.
  defp drawing(%{id: :new_player_watch} = assigns) do
    ~H"""
    <circle cx="15" cy="28" r="8" fill="currentColor" fill-opacity=".14" />
    <circle cx="33" cy="28" r="8" fill="currentColor" fill-opacity=".14" />
    <path d="M23 26h2M11 20l3-10h6l2 10M37 20l-3-10h-6l-2 10" />
    """
  end

  # A podium, the top three.
  defp drawing(%{id: id} = assigns) when id in [:top_command, :match_end_leaderboard] do
    ~H"""
    <path d="M18 18h12v22H18z" fill="currentColor" fill-opacity=".2" />
    <path d="M6 26h12v14H6zM30 30h12v10H30z" fill="currentColor" fill-opacity=".1" />
    <path d="M24 6l1.8 3.7 4 .6-2.9 2.8.7 4-3.6-1.9-3.6 1.9.7-4-2.9-2.8 4-.6z" />
    <path :if={@id == :match_end_leaderboard} d="M4 44h40" />
    """
  end

  # A medic's cross on a VIP ribbon.
  defp drawing(%{id: :top_support_vip} = assigns) do
    ~H"""
    <circle cx="24" cy="20" r="11" fill="currentColor" fill-opacity=".14" />
    <path d="M24 14v12M18 20h12" />
    <path d="M17 29l-3 13 10-5 10 5-3-13" />
    """
  end

  # A star on a medal: the best of the match.
  defp drawing(%{id: :mvp_vip} = assigns) do
    ~H"""
    <path d="M16 6l4 10M32 6l-4 10" />
    <circle cx="24" cy="28" r="12" fill="currentColor" fill-opacity=".14" />
    <path d="M24 21l2.2 4.4 4.8.7-3.5 3.4.8 4.8-4.3-2.3-4.3 2.3.8-4.8-3.5-3.4 4.8-.7z" />
    """
  end

  # Four soldiers in a row under a laurel: the whole squad.
  defp drawing(%{id: :best_squad_vip} = assigns) do
    ~H"""
    <circle cx="10" cy="26" r="3" /><circle cx="19.3" cy="26" r="3" />
    <circle cx="28.7" cy="26" r="3" /><circle cx="38" cy="26" r="3" />
    <path d="M5 38c0-4 2-6 5-6s5 2 5 6M14 38c0-4 2-6 5-6s5 2 5 6M24 38c0-4 2-6 5-6s5 2 5 6M33 38c0-4 2-6 5-6s5 2 5 6" />
    <path d="M12 16c4-6 20-6 24 0" fill="currentColor" fill-opacity=".14" />
    <path d="M24 8v4" />
    """
  end

  # A field radio with its antenna: the commander's.
  defp drawing(%{id: :commander_reward} = assigns) do
    ~H"""
    <rect x="10" y="18" width="28" height="22" rx="3" fill="currentColor" fill-opacity=".14" />
    <path d="M30 18L36 6" />
    <circle cx="19" cy="29" r="4" />
    <path d="M28 25h5M28 29h5M28 33h5" />
    """
  end

  # A flag carried forward: leading the squad.
  defp drawing(%{id: :squad_leader_reward} = assigns) do
    ~H"""
    <path d="M14 42V6" />
    <path d="M14 8h22l-5 7 5 7H14" fill="currentColor" fill-opacity=".14" />
    <path d="M22 36l4 4 8-8" />
    """
  end

  # A trench knife.
  defp drawing(%{id: :melee_kill} = assigns) do
    ~H"""
    <path d="M30 18L14 34l-2 4 4-2 16-16" fill="currentColor" fill-opacity=".14" />
    <path d="M28 16l4 4M34 10l4 4-4 4-4-4z" />
    <path d="M36 8l4-4" />
    """
  end

  # Anything added later still gets a mark rather than nothing.
  defp drawing(assigns) do
    ~H"""
    <rect x="8" y="8" width="32" height="32" rx="8" fill="currentColor" fill-opacity=".14" />
    <path d="M26 14l-8 11h6l-2 9 8-11h-6z" />
    """
  end
end
