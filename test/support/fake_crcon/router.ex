defmodule HllConditionalActions.FakeCrcon.Router do
  @moduledoc """
  The Plug behind `HllConditionalActions.FakeCrcon`.

  Kept separate from the fake's helpers because `Plug` and `Supervisor` both
  define `init/1`, and Bandit calls the Plug one.
  """

  @behaviour Plug

  alias HllConditionalActions.FakeCrcon.Socket

  @impl Plug
  def init(mode), do: mode

  @impl Plug
  def call(%{request_path: "/ws/logs"} = conn, :unauthorized) do
    conn |> Plug.Conn.send_resp(403, "forbidden") |> Plug.Conn.halt()
  end

  def call(%{request_path: "/ws/logs"} = conn, mode) do
    conn
    |> WebSockAdapter.upgrade(Socket, mode, timeout: 60_000)
    |> Plug.Conn.halt()
  end

  def call(conn, _mode), do: Plug.Conn.send_resp(conn, 404, "not found")
end
