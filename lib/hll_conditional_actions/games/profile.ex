defmodule HllConditionalActions.Games.Profile do
  @moduledoc """
  Game specific reference data behind a stable interface.

  CRCON (`hll_rcon_tool`) ships one profile per supported game under
  `rcon/game/hll` and `rcon/game/hllv`. We mirror that split: every piece of
  data that differs between Hell Let Loose (WW2) and Hell Let Loose: Vietnam
  lives in `HllConditionalActions.Games.Hll` or
  `HllConditionalActions.Games.Hllv`, and everything else is written against
  this struct.

  The `id` matches CRCON's `GameEnum` values (`"hll"` / `"hllv"`), which is what
  the `HLL_GAME` environment variable of a CRCON deployment is set to.
  """

  alias HllConditionalActions.Games.Profile

  @type game :: :hll | :hllv
  @type option :: %{value: String.t(), label: String.t()}
  @type role :: %{
          value: String.t(),
          label: String.t(),
          type: atom(),
          squad_leader?: boolean()
        }

  @type t :: %__MODULE__{
          id: game(),
          label: String.t(),
          short_label: String.t(),
          teams: [option()],
          roles: [role()],
          game_modes: [option()],
          role_types: [atom()]
        }

  @enforce_keys [:id, :label, :short_label, :teams, :roles, :game_modes]
  defstruct [:id, :label, :short_label, :teams, :roles, :game_modes, role_types: []]

  @doc """
  Returns the profile for a game.
  """
  @callback profile() :: t()

  @doc """
  Returns the roles of a profile that belong to the given role type.

      iex> alias HllConditionalActions.Games
      iex> Games.profile!(:hllv) |> Games.Profile.roles_of_type(:helicopter) |> Enum.map(& &1.value)
      ["helicopterpilot", "helicopterlogisticsofficer"]
  """
  @spec roles_of_type(t(), atom()) :: [role()]
  def roles_of_type(%Profile{roles: roles}, type) do
    Enum.filter(roles, &(&1.type == type))
  end

  @doc """
  Returns the squad leader roles of a profile.
  """
  @spec squad_leader_roles(t()) :: [role()]
  def squad_leader_roles(%Profile{roles: roles}) do
    Enum.filter(roles, & &1.squad_leader?)
  end

  @doc """
  Returns `{label, value}` tuples suitable for a `<select>` input.
  """
  @spec role_options(t()) :: [{String.t(), String.t()}]
  def role_options(%Profile{roles: roles}) do
    Enum.map(roles, &{&1.label, &1.value})
  end

  @doc """
  Returns `{label, value}` tuples of the teams, suitable for a `<select>` input.
  """
  @spec team_options(t()) :: [{String.t(), String.t()}]
  def team_options(%Profile{teams: teams}) do
    Enum.map(teams, &{&1.label, &1.value})
  end

  @doc """
  Returns `{label, value}` tuples of the game modes, suitable for a `<select>` input.
  """
  @spec game_mode_options(t()) :: [{String.t(), String.t()}]
  def game_mode_options(%Profile{game_modes: modes}) do
    Enum.map(modes, &{&1.label, &1.value})
  end

  @doc """
  Looks a role up by the value CRCON reports for a player.

  CRCON lowercases the game's internal role name, so `"HeavyMachineGunner"`
  arrives as `"heavymachinegunner"`. Lookups are therefore case insensitive.
  """
  @spec fetch_role(t(), String.t() | nil) :: {:ok, role()} | :error
  def fetch_role(%Profile{}, nil), do: :error

  def fetch_role(%Profile{roles: roles}, value) when is_binary(value) do
    downcased = String.downcase(value)

    case Enum.find(roles, &(&1.value == downcased)) do
      nil -> :error
      role -> {:ok, role}
    end
  end
end
