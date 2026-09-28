defmodule HllConditionalActions.Crcon.GameText do
  @moduledoc """
  Text as the game can show it.

  Hell Let Loose draws messages, broadcasts, the welcome screen and kick or
  ban reasons with a font that has no emoji and few symbols: an emoji comes
  out as an empty box or a question mark, or not at all. Every text that
  reaches the game goes through `clean/1`, in `HllConditionalActions.Crcon`,
  so neither the app's own messages nor what an admin types can break a
  message on screen.

  What is removed or replaced:

    * emoji, pictographs, flags, and the joiners and variation selectors that
      build them
    * typographic quotes, dashes, ellipsis and bullets, turned into their
      plain ASCII forms
    * non-breaking and zero-width spaces

  Accented letters stay: they are part of the players' languages and the
  game shows them.
  """

  @replacements [
    {~r/[\x{2018}\x{2019}\x{201A}\x{2032}]/u, "'"},
    {~r/[\x{201C}\x{201D}\x{201E}\x{2033}]/u, "\""},
    {~r/[\x{2013}\x{2014}\x{2212}]/u, "-"},
    {~r/\x{2026}/u, "..."},
    {~r/[\x{2022}\x{00B7}\x{25CF}]/u, "-"},
    {~r/[\x{00A0}\x{2007}\x{202F}]/u, " "}
  ]

  # Emoji and pictographs, dingbats and symbols, regional indicators (flags),
  # keycaps, variation selectors, joiners and other invisible format marks.
  @unsupported ~r/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{2300}-\x{23FF}\x{2190}-\x{21FF}\x{25A0}-\x{25FF}\x{E000}-\x{F8FF}\x{FE00}-\x{FE0F}\x{20E3}\x{200B}-\x{200F}\x{2060}-\x{2064}\x{E0000}-\x{E007F}]/u

  @doc """
  The text with everything the game cannot draw removed or replaced.

      iex> alias HllConditionalActions.Crcon.GameText
      iex> GameText.clean("🏆 Winner: Ana 🎉")
      "Winner: Ana"
      iex> GameText.clean("“Sniper” — 3 kills…")
      "\\"Sniper\\" - 3 kills..."
      iex> GameText.clean("Olá, você ganhou!")
      "Olá, você ganhou!"
      iex> GameText.clean("line one 👍\\nline two")
      "line one\\nline two"
  """
  @spec clean(String.t() | nil) :: String.t()
  def clean(nil), do: ""

  def clean(text) when is_binary(text) do
    text =
      Enum.reduce(@replacements, text, fn {pattern, with}, acc ->
        Regex.replace(pattern, acc, with)
      end)

    text
    |> String.replace(@unsupported, "")
    # What the removal left behind: double spaces and spaces at line ends.
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.replace(~r/ {2,}/, " ") |> String.trim() end)
    |> String.trim()
  end

  @doc """
  Whether the game would show the text differently from how it was typed.

      iex> HllConditionalActions.Crcon.GameText.changes?("gg 🔥")
      true
      iex> HllConditionalActions.Crcon.GameText.changes?("gg")
      false
  """
  @spec changes?(String.t() | nil) :: boolean()
  def changes?(nil), do: false

  def changes?(text) when is_binary(text),
    do:
      String.replace(text, @unsupported, "") != text or
        Enum.any?(@replacements, fn {p, _} -> Regex.match?(p, text) end)
end
