defmodule HllConditionalActionsWeb.ShopAssetController do
  @moduledoc """
  Serves the storefront's uploaded images (logo, banner) from the database.
  A replaced image gets a new id, so each one can be cached for good.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActions.VipShop

  def show(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {id, ""} -> serve(conn, VipShop.get_asset(id))
      _other -> send_resp(conn, 404, "")
    end
  end

  defp serve(conn, nil), do: send_resp(conn, 404, "")

  defp serve(conn, asset) do
    conn
    |> put_resp_content_type(asset.content_type, nil)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, asset.data)
  end
end
