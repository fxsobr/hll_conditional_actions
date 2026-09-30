defmodule HllConditionalActionsWeb.NumberFormat do
  @moduledoc """
  Numbers the way the viewer's language writes them: "12.480" and "91,7%"
  in Portuguese and Spanish, "12,480" and "91.7%" in English.
  """

  @comma_decimal ~w(pt_BR pt es de fr)

  @doc """
  The thousands separator and the decimal mark of the current locale.

      iex> Gettext.with_locale(HllConditionalActionsWeb.Gettext, "es", fn ->
      ...>   HllConditionalActionsWeb.NumberFormat.separators()
      ...> end)
      {".", ","}
  """
  @spec separators() :: {String.t(), String.t()}
  def separators do
    if Gettext.get_locale(HllConditionalActionsWeb.Gettext) in @comma_decimal,
      do: {".", ","},
      else: {",", "."}
  end

  @doc """
  A whole number with thousands grouped.

      iex> Gettext.with_locale(HllConditionalActionsWeb.Gettext, "en", fn ->
      ...>   HllConditionalActionsWeb.NumberFormat.integer(-12480)
      ...> end)
      "-12,480"
  """
  @spec integer(integer()) :: String.t()
  def integer(value) when value < 0, do: "-" <> integer(-value)

  def integer(value) when is_integer(value) do
    {thousands, _decimal} = separators()

    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(thousands, &Enum.join/1)
    |> String.reverse()
  end

  @doc """
  A number with `places` decimals and the locale's decimal mark.

      iex> Gettext.with_locale(HllConditionalActionsWeb.Gettext, "pt_BR", fn ->
      ...>   HllConditionalActionsWeb.NumberFormat.decimal(91.66, 1)
      ...> end)
      "91,7"
  """
  @spec decimal(number(), non_neg_integer()) :: String.t()
  def decimal(value, places) when value < 0, do: "-" <> decimal(-value, places)

  def decimal(value, places) do
    {_thousands, mark} = separators()

    case value
         |> Kernel.*(1.0)
         |> :erlang.float_to_binary(decimals: places)
         |> String.split(".") do
      [whole] -> integer(String.to_integer(whole))
      [whole, decimals] -> integer(String.to_integer(whole)) <> mark <> decimals
    end
  end
end
