defmodule HllConditionalActionsWeb.SessionControllerTest do
  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts

  describe "GET /login" do
    test "renders the form", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert html_response(conn, 200) =~ "Sign in"
    end

    test "shows the bootstrap credentials only while they are still in use", %{conn: conn} do
      :ok = Accounts.bootstrap!()

      assert get(conn, ~p"/login") |> html_response(200) =~ ~s(id="first-run-hint")

      admin = Accounts.get_user_by_username("admin")

      {:ok, _user} =
        Accounts.update_password(admin, %{
          password: "somethingelse1",
          password_confirmation: "somethingelse1"
        })

      refute build_conn() |> get(~p"/login") |> html_response(200) =~ ~s(id="first-run-hint")
    end
  end

  describe "POST /login" do
    setup do
      %{
        user:
          user_fixture(%{
            username: "ana",
            password: "supersecret123",
            password_confirmation: "supersecret123"
          })
      }
    end

    test "signs the user in and lands on the dashboard", %{conn: conn} do
      conn = post(conn, ~p"/login", user: %{username: "ana", password: "supersecret123"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id)
    end

    test "sends a user with the forced flag to the password form", %{conn: conn} do
      _user =
        user_fixture(%{
          username: "bob",
          password: "supersecret123",
          password_confirmation: "supersecret123",
          must_change_password?: true
        })

      conn = post(conn, ~p"/login", user: %{username: "bob", password: "supersecret123"})

      assert redirected_to(conn) == ~p"/account/password"
    end

    test "rejects a wrong password without saying which half was wrong", %{conn: conn} do
      conn = post(conn, ~p"/login", user: %{username: "ana", password: "nope"})

      response = html_response(conn, 401)
      assert response =~ "Wrong username or password"
      refute get_session(conn, :user_id)
    end

    test "returns the visitor to where they were headed", %{conn: conn} do
      conn = get(conn, ~p"/servers")
      assert redirected_to(conn) == ~p"/login"

      conn = post(conn, ~p"/login", user: %{username: "ana", password: "supersecret123"})
      assert redirected_to(conn) == ~p"/servers"
    end
  end

  describe "DELETE /logout" do
    test "clears the session", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> HllConditionalActionsWeb.UserAuth.log_in_user(user)
        |> recycle()
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
    end
  end

  describe "authorization" do
    test "an anonymous visitor is sent to the login page", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == ~p"/login"
      assert conn |> get(~p"/servers") |> redirected_to() == ~p"/login"
      assert conn |> get(~p"/users") |> redirected_to() == ~p"/login"
    end

    test "health probes stay open", %{conn: conn} do
      assert conn |> get(~p"/health") |> json_response(200) |> Map.get("status") == "ok"
    end
  end
end
