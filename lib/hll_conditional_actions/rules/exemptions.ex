defmodule HllConditionalActions.Rules.Exemptions do
  @moduledoc """
  The players a rule never applies to.

  Checked by the engine *before* any condition is evaluated, so an exempt
  player costs nothing and never reaches the actions - a kick rule cannot
  kick a VIP because a condition was written a little too broadly.

  What CRCON tells us about a player is all there is to go on:

    * `exempt_vip` - the player holds VIP on the server (`is_vip` in the
      detailed player list)
    * `exempt_flags` - the player carries any of these CRCON flags in their
      profile (communities usually flag their staff, so this is also how
      admins and moderators are exempted)
    * `exempt_player_ids` - specific players, by id

  List values arrive from the builder as one comma separated string and are
  split here, so the form and the JSON import can both send either shape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field :exempt_vip, :boolean, default: false
    field :exempt_flags, {:array, :string}, default: []
    field :exempt_player_ids, {:array, :string}, default: []
  end

  @doc """
  Builds a changeset for a rule's exemptions.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(exemptions, attrs) do
    attrs = split_lists(attrs)

    exemptions
    |> cast(attrs, [:exempt_vip, :exempt_flags, :exempt_player_ids])
    |> update_change(:exempt_flags, &clean_list/1)
    |> update_change(:exempt_player_ids, &clean_list/1)
  end

  @doc """
  Whether any exemption is set.

      iex> alias HllConditionalActions.Rules.Exemptions
      iex> {Exemptions.active?(nil), Exemptions.active?(%Exemptions{exempt_vip: true})}
      {false, true}
  """
  @spec active?(t() | nil) :: boolean()
  def active?(nil), do: false

  def active?(%__MODULE__{} = exemptions) do
    exemptions.exempt_vip or exemptions.exempt_flags != [] or
      exemptions.exempt_player_ids != []
  end

  @doc """
  Whether a player is exempt, given what is known about them: `:player_id`,
  `:is_vip` and `:flags`.

      iex> alias HllConditionalActions.Rules.Exemptions
      iex> exemptions = %Exemptions{exempt_vip: true, exempt_flags: ["staff"]}
      iex> Exemptions.exempt?(exemptions, %{player_id: "1", is_vip: true, flags: []})
      true
      iex> Exemptions.exempt?(exemptions, %{player_id: "1", is_vip: false, flags: ["Staff"]})
      true
      iex> Exemptions.exempt?(exemptions, %{player_id: "1", is_vip: false, flags: nil})
      false
  """
  @spec exempt?(t() | nil, map()) :: boolean()
  def exempt?(nil, _player), do: false

  def exempt?(%__MODULE__{} = exemptions, player) do
    vip?(exemptions, player) or flagged?(exemptions, player) or listed?(exemptions, player)
  end

  defp vip?(%{exempt_vip: true}, %{is_vip: vip}), do: vip in [true, "true"]
  defp vip?(_exemptions, _player), do: false

  defp flagged?(%{exempt_flags: []}, _player), do: false

  defp flagged?(%{exempt_flags: wanted}, %{flags: flags}) when is_list(flags) do
    wanted = MapSet.new(wanted, &normalize/1)
    Enum.any?(flags, &(normalize(&1) in wanted))
  end

  defp flagged?(_exemptions, _player), do: false

  defp listed?(%{exempt_player_ids: ids}, %{player_id: id}) when is_binary(id), do: id in ids
  defp listed?(_exemptions, _player), do: false

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp split_lists(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(value) ->
        if to_string(key) in ~w(exempt_flags exempt_player_ids),
          do: {key, String.split(value, ",")},
          else: {key, value}

      pair ->
        pair
    end)
  end

  defp split_lists(attrs), do: attrs

  defp clean_list(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp clean_list(values), do: values
end
