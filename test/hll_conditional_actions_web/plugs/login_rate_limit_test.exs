defmodule HllConditionalActionsWeb.LoginRateLimitTest do
  @moduledoc """
  The sign in form is the only thing this app exposes to whoever finds the
  address, so what it refuses — and what it gives away while refusing — is
  worth a test of its own.

  Not async: it lowers the limits for the whole application.
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.RateLimit

  setup do
    previous = Application.get_env(:hll_conditional_actions, :login_rate_limit)

    Application.put_env(:hll_conditional_actions, :login_rate_limit,
      ip: [limit: 3, window_ms: 60_000],
      username: [limit: 5, window_ms: 3_600_000]
    )

    # The counters outlive the database sandbox, so each test starts by
    # clearing the two keys it is about to spend.
    clear = fn ->
      RateLimit.reset("login:ip:127.0.0.1")
      RateLimit.reset("login:user:sarge")
    end

    on_exit(fn ->
      Application.put_env(:hll_conditional_actions, :login_rate_limit, previous)
      clear.()
    end)

    clear.()

    user =
      user_fixture(%{
        username: "sarge",
        password: "wintergreen1",
        password_confirmation: "wintergreen1"
      })

    %{user: user}
  end

  defp attempt(conn, username, password) do
    post(conn, ~p"/login", %{"user" => %{"username" => username, "password" => password}})
  end

  test "a wrong password is refused without saying whether the account exists", %{conn: conn} do
    response = conn |> attempt("sarge", "wrong") |> html_response(401)

    assert response =~ "Wrong username or password"
  end

  test "too many attempts stop being answered", %{conn: conn} do
    for _attempt <- 1..3 do
      assert conn |> attempt("sarge", "wrong") |> Map.fetch!(:status) == 401
    end

    conn = attempt(conn, "sarge", "wrong")

    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "the refusal does not confirm the account exists", %{conn: conn} do
    for _attempt <- 1..4, do: attempt(conn, "sarge", "wrong")

    response = conn |> attempt("sarge", "wrong") |> html_response(429)

    # The wording is about the attempts, never about the account: "no such
    # user" and "that account is locked" both answer the question an attacker
    # is really asking.
    assert response =~ "Too many sign in attempts"
    refute response =~ "does not exist"
    refute response =~ "locked"
  end

  test "the right password still works below the limit", %{conn: conn} do
    conn = attempt(conn, "sarge", "wintergreen1")

    assert redirected_to(conn) == ~p"/"
  end

  test "signing in clears the counter, so earlier typos are forgotten", %{conn: conn} do
    attempt(conn, "sarge", "wrong")
    attempt(conn, "sarge", "wrong")

    conn |> attempt("sarge", "wintergreen1") |> redirected_to()

    # Only the successful attempt is on the clock now, so three more fit.
    for _attempt <- 1..3 do
      assert build_conn() |> attempt("sarge", "wrong") |> Map.fetch!(:status) == 401
    end
  end

  test "the username counter survives a change of address", %{conn: conn} do
    # Five attempts spread over addresses, none of which reaches the per
    # address limit of three on its own.
    for address <- [{203, 0, 113, 1}, {203, 0, 113, 2}, {203, 0, 113, 3}] do
      %{conn | remote_ip: address} |> attempt("sarge", "wrong")
      %{conn | remote_ip: address} |> attempt("sarge", "wrong")
    end

    refused = %{conn | remote_ip: {203, 0, 113, 9}} |> attempt("sarge", "wrong")

    assert refused.status == 429
  after
    for last <- 1..9, do: RateLimit.reset("login:ip:203.0.113.#{last}")
    RateLimit.reset("login:user:sarge")
  end

  test "GET /login is never throttled, so nobody is locked out of the form", %{conn: conn} do
    for _attempt <- 1..5, do: attempt(conn, "sarge", "wrong")

    assert conn |> get(~p"/login") |> html_response(200)
  end
end
