defmodule HllConditionalActionsWeb.Plugs.StaleLoginForm do
  @moduledoc """
  Sends an expired sign in form back to a fresh one.

  A login page that has been open since before the session changed - a
  restarted server, cleared cookies, or the back button after signing out -
  still carries the CSRF token of a session that no longer exists. Refusing it
  is correct, and `:protect_from_forgery` does exactly that by raising, but the
  visitor gets an error page for something whose only fix is to load the form
  again.

  So the sign in form, and only the sign in form, is checked one step earlier
  with the same function `Plug.CSRFProtection` uses itself. A token that does
  not match sends the visitor back to a freshly rendered form; a token that
  does match falls through to `:protect_from_forgery` as usual, which is still
  what protects the request. Nothing is accepted here that would otherwise have
  been rejected.

  Must be piped through *before* `:protect_from_forgery`, or the raise will
  have happened already.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/login"} = conn, _opts) do
    if skipped?(conn) or valid_token?(conn) do
      conn
    else
      conn
      |> put_resp_header("location", "/login?expired=1")
      |> send_resp(:found, "")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  # `Plug.CSRFProtection` steps aside when a caller has set this - which
  # `Phoenix.ConnTest` does for every request - and so must we. Judging a
  # request stale that the protection itself would have waved through would
  # turn a redirect into the only answer a controller test ever gets.
  defp skipped?(conn), do: conn.private[:plug_skip_csrf_protection] == true

  defp valid_token?(conn) do
    state = Plug.CSRFProtection.dump_state_from_session(get_session(conn, "_csrf_token"))
    token = conn.params["_csrf_token"] || List.first(get_req_header(conn, "x-csrf-token"))

    is_binary(state) and is_binary(token) and
      Plug.CSRFProtection.valid_state_and_csrf_token?(state, token)
  end
end
