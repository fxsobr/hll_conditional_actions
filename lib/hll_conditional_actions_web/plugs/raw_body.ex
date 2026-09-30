defmodule HllConditionalActionsWeb.Plugs.RawBody do
  @moduledoc """
  Keeps the exact request body of payment webhooks.

  Providers sign the body as they sent it; once `Plug.Parsers` has decoded
  the JSON, re-encoding it would not reproduce the same bytes. Used as the
  parsers' `:body_reader`, it stores the raw body in `conn.assigns.raw_body`
  for `/webhooks/*` only, so no other request pays for the copy.
  """

  @doc false
  def read_body(%Plug.Conn{request_path: "/webhooks/" <> _rest} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      {:more, body, conn} ->
        {:more, body, Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)}

      other ->
        other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
end
