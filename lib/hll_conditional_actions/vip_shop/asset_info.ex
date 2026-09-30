defmodule HllConditionalActions.VipShop.AssetInfo do
  @moduledoc """
  What the storefront editor says about an uploaded image: its type, its
  size in bytes and its dimensions, read from the file's own header.
  """

  import Ecto.Query

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop.Asset

  @doc "An image's type, bytes and dimensions, or nil when it is gone."
  @spec get(term()) :: map() | nil
  def get(nil), do: nil

  def get(id) do
    case Repo.one(from a in Asset, where: a.id == ^id, select: {a.content_type, a.data}) do
      nil ->
        nil

      {type, data} ->
        {width, height} = dimensions(data)

        %{
          id: id,
          format: type |> String.replace("image/", "") |> String.upcase(),
          bytes: byte_size(data),
          width: width,
          height: height
        }
    end
  end

  @doc """
  An image's width and height from its header: PNG, GIF, JPEG and WebP.

      iex> HllConditionalActions.VipShop.AssetInfo.dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 512::32, 256::32>>)
      {512, 256}
      iex> HllConditionalActions.VipShop.AssetInfo.dimensions("nope")
      {nil, nil}
  """
  @spec dimensions(binary()) :: {pos_integer() | nil, pos_integer() | nil}
  def dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: {w, h}

  def dimensions(<<"GIF8", _v::binary-size(2), w::little-16, h::little-16, _::binary>>),
    do: {w, h}

  def dimensions(
        <<"RIFF", _size::32, "WEBPVP8X", _chunk::32, _flags::32, w::little-24, h::little-24,
          _::binary>>
      ),
      do: {w + 1, h + 1}

  def dimensions(
        <<"RIFF", _size::32, "WEBPVP8 ", _chunk::32, _frame::binary-size(3), 0x9D, 0x01, 0x2A,
          w::little-16, h::little-16, _::binary>>
      ),
      do: {Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF)}

  def dimensions(<<"RIFF", _size::32, "WEBPVP8L", _chunk::32, 0x2F, bits::little-32, _::binary>>),
    do: {Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)
  def dimensions(_data), do: {nil, nil}

  # Walks the JPEG markers to the first frame header (SOF0-SOF15 but the
  # DHT, JPG and DAC markers).
  defp jpeg(<<0xFF, marker, _len::16, _precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {w, h}

  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_skip::binary-size(^skip), next::binary>> -> jpeg(next)
      _short -> {nil, nil}
    end
  end

  defp jpeg(_data), do: {nil, nil}
end
