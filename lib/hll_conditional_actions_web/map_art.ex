defmodule HllConditionalActionsWeb.MapArt do
  @moduledoc """
  The artwork of a map, from the images shipped under
  `priv/static/images/maps/<game>/` (taken from CRCON, see the NOTICE there).

  Files are named the way CRCON names them, `<map id>-<environment>.webp`, so
  a layer's own `image_name` finds its picture directly. Without one - a
  match from the history, a map known only by its name - the name is folded
  to the map id ("St. Marie Du Mont" to `stmariedumont`) and its day picture
  is used, then the game's "unknown" picture.
  """

  @root Path.expand("../../priv/static/images/maps", __DIR__)

  @files (for game <- ~w(hll hllv), into: %{} do
            dir = Path.join(@root, game)
            @external_resource dir

            files =
              case File.ls(dir) do
                {:ok, files} ->
                  files |> Enum.filter(&String.ends_with?(&1, ".webp")) |> MapSet.new()

                {:error, _reason} ->
                  MapSet.new()
              end

            {game, files}
          end)

  @doc """
  The URL of a map's picture.

  `map` is a CRCON layer map (with `"image_name"`, or `"id"` / a nested
  `"map" => %{"id" => ...}`), or a map's pretty name.

      iex> alias HllConditionalActionsWeb.MapArt
      iex> MapArt.url(:hll, %{"image_name" => "foy-night.webp"})
      "/images/maps/hll/foy-night.webp"
      iex> MapArt.url(:hll, "St. Marie Du Mont")
      "/images/maps/hll/stmariedumont-day.webp"
      iex> MapArt.url(:hll, "Somewhere new")
      "/images/maps/hll/unknown.webp"
  """
  @spec url(atom() | String.t(), map() | String.t() | nil) :: String.t()
  def url(game, map) do
    game = folder(game)

    map
    |> candidates()
    |> Enum.find(&MapSet.member?(@files[game], &1))
    |> case do
      nil -> "/images/maps/#{game}/unknown.webp"
      file -> "/images/maps/#{game}/#{file}"
    end
  end

  defp folder(game) when game in [:hllv, "hllv"], do: "hllv"
  defp folder(_game), do: "hll"

  defp candidates(%{"image_name" => image} = map) when is_binary(image),
    do: [String.downcase(image) | candidates(Map.delete(map, "image_name"))]

  defp candidates(%{"map" => %{"id" => id}} = map) when is_binary(id),
    do: day(id) ++ candidates(Map.delete(map, "map"))

  defp candidates(%{"id" => id} = map) when is_binary(id),
    do: day(id |> String.split("_") |> List.first()) ++ candidates(Map.delete(map, "id"))

  defp candidates(%{"pretty_name" => name}) when is_binary(name), do: candidates(name)
  defp candidates(name) when is_binary(name), do: day(fold(name))
  defp candidates(_unknown), do: []

  defp day(id), do: ["#{String.downcase(id)}-day.webp"]

  # "St. Marie Du Mont" -> "stmariedumont"; "Hill 400" -> "hill400".
  defp fold(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\s*\(.*\)\s*/, "")
    |> String.replace(~r/[^a-z0-9]/, "")
  end
end
