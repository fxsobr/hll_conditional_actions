defmodule HllConditionalActions.VipShop.Asset do
  @moduledoc """
  An image uploaded for the storefront, such as the logo or the banner.

  Stored in the database rather than on disk, so it survives a container
  being rebuilt without a volume. Only common web image types are accepted,
  and they are served back with their own content type.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @content_types ~w(image/png image/jpeg image/webp image/gif)
  @max_bytes 2_000_000

  schema "vip_shop_assets" do
    field :kind, :string
    field :content_type, :string
    field :data, :binary
    field :byte_size, :integer

    timestamps(type: :utc_datetime)
  end

  @doc "The image types accepted, as file extensions for the upload input."
  @spec extensions() :: [String.t()]
  def extensions, do: ~w(.png .jpg .jpeg .webp .gif)

  @doc "The largest image accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc false
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:kind, :content_type, :data])
    |> validate_required([:kind, :content_type, :data])
    |> validate_inclusion(:content_type, @content_types)
    |> put_size()
    |> validate_number(:byte_size, less_than_or_equal_to: @max_bytes)
  end

  defp put_size(changeset) do
    case get_change(changeset, :data) do
      data when is_binary(data) -> put_change(changeset, :byte_size, byte_size(data))
      _missing -> changeset
    end
  end
end
