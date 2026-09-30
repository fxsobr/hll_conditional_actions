defmodule HllConditionalActionsWeb.AccountSessionsTest do
  @moduledoc """
  The browsers an account is signed in on, and changing the password: the
  account page lists the sessions, ends them, and a new password (which
  needs the current one) signs out every other browser.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.User

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  setup %{conn: conn} do
    user = user_fixture()
    {token, mine} = Sessions.create(user, %{user_agent: @chrome, ip: "10.0.0.1"})
    {_other_token, other} = Sessions.create(user, %{user_agent: @iphone, ip: "10.0.0.2"})

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)
      |> Plug.Conn.put_session(:session_token, token)

    %{conn: conn, user: user, mine: mine, other: other}
  end

  test "lists the sessions, this one first", %{conn: conn, mine: mine, other: other} do
    {:ok, view, _html} = live(conn, ~p"/account")

    assert has_element?(view, "#account-session-#{mine.id}", "Chrome · Windows")
    assert has_element?(view, "#account-session-#{other.id}", "Safari · iPhone")
    refute has_element?(view, "#account-end-session-#{mine.id}")
  end

  test "ends another session, which is then signed out", %{conn: conn, user: user, other: other} do
    {:ok, view, _html} = live(conn, ~p"/account")

    view |> element("#account-end-session-#{other.id}") |> render_click()

    refute has_element?(view, "#account-session-#{other.id}")

    assert Enum.map(Sessions.list(user), & &1.id) != [] and
             other.id not in Enum.map(Sessions.list(user), & &1.id)
  end

  test "ends every other session at once", %{conn: conn, user: user, mine: mine} do
    {:ok, view, _html} = live(conn, ~p"/account")

    view |> element("#account-end-other-sessions") |> render_click()

    assert Enum.map(Sessions.list(user), & &1.id) == [mine.id]
  end

  test "a signed out token no longer opens a page", %{conn: conn, other: other, user: user} do
    {token, session} = Sessions.create(user, %{})
    Sessions.revoke(user, session.id)

    conn =
      conn
      |> recycle()
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)
      |> Plug.Conn.put_session(:session_token, token)

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")
    assert other.id in Enum.map(Sessions.list(user), & &1.id)
  end

  describe "changing the password" do
    test "needs the current one", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#password-change-form", %{
        "password" => %{
          "current_password" => "wrong password",
          "password" => "a new passw0rd here",
          "password_confirmation" => "a new passw0rd here"
        }
      })
      |> render_submit()

      assert User.valid_password?(reload(user), "supersecret123")
    end

    test "follows the policy", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#password-change-form", %{
        "password" => %{
          "current_password" => "supersecret123",
          "password" => "short1",
          "password_confirmation" => "short1"
        }
      })
      |> render_submit()

      assert User.valid_password?(reload(user), "supersecret123")
    end

    test "saves it and signs out the other sessions", %{conn: conn, user: user, mine: mine} do
      {:ok, view, _html} = live(conn, ~p"/account")

      view
      |> form("#password-change-form", %{
        "password" => %{
          "current_password" => "supersecret123",
          "password" => "a new passw0rd here",
          "password_confirmation" => "a new passw0rd here"
        }
      })
      |> render_submit()

      assert User.valid_password?(reload(user), "a new passw0rd here")
      assert Enum.map(Sessions.list(user), & &1.id) == [mine.id]
    end
  end

  defp reload(user), do: HllConditionalActions.Repo.get!(User, user.id)
end
