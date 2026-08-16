defmodule HllConditionalActions.Games do
  @moduledoc """
  Registry of the games this application can drive.

  Every CRCON deployment serves exactly one game, declared by its `HLL_GAME`
  environment variable. A `HllConditionalActions.Servers.Server` therefore
  carries a `game` field, and the rest of the system asks this module for the
  matching `HllConditionalActions.Games.Profile`.
  """

  alias HllConditionalActions.Games.Hll
  alias HllConditionalActions.Games.Hllv
  alias HllConditionalActions.Games.Profile

  @modules %{hll: Hll, hllv: Hllv}
  @games Map.keys(@modules)

  @doc """
  Returns every supported game id, in display order.

      iex> HllConditionalActions.Games.all()
      [:hll, :hllv]
  """
  @spec all() :: [Profile.game()]
  def all, do: Enum.sort(@games)

  @doc """
  Returns every supported profile, in display order.
  """
  @spec profiles() :: [Profile.t()]
  def profiles, do: Enum.map(all(), &profile!/1)

  @doc """
  Fetches the profile for a game.

      iex> {:ok, profile} = HllConditionalActions.Games.fetch_profile("hllv")
      iex> profile.short_label
      "HLLV"

      iex> HllConditionalActions.Games.fetch_profile("battlefield")
      :error
  """
  @spec fetch_profile(Profile.game() | String.t() | nil) :: {:ok, Profile.t()} | :error
  def fetch_profile(game) do
    with {:ok, id} <- cast(game) do
      {:ok, @modules |> Map.fetch!(id) |> then(& &1.profile())}
    end
  end

  @doc """
  Same as `fetch_profile/1` but raises when the game is unknown.
  """
  @spec profile!(Profile.game() | String.t()) :: Profile.t()
  def profile!(game) do
    case fetch_profile(game) do
      {:ok, profile} ->
        profile

      :error ->
        raise ArgumentError,
              "unknown game #{inspect(game)}, expected one of: #{Enum.map_join(all(), ", ", &to_string/1)}"
    end
  end

  @doc """
  Casts an external value (form input, CRCON payload) to a game id.

      iex> HllConditionalActions.Games.cast("hll")
      {:ok, :hll}

      iex> HllConditionalActions.Games.cast(:hllv)
      {:ok, :hllv}

      iex> HllConditionalActions.Games.cast(nil)
      :error
  """
  @spec cast(term()) :: {:ok, Profile.game()} | :error
  def cast(game) when game in @games, do: {:ok, game}

  def cast(game) when is_binary(game) do
    case String.downcase(game) do
      "hll" -> {:ok, :hll}
      "hllv" -> {:ok, :hllv}
      _other -> :error
    end
  end

  def cast(_other), do: :error

  @doc """
  Returns `{label, value}` tuples of every game, suitable for a `<select>` input.
  """
  @spec options() :: [{String.t(), String.t()}]
  def options do
    Enum.map(profiles(), &{&1.label, to_string(&1.id)})
  end
end
