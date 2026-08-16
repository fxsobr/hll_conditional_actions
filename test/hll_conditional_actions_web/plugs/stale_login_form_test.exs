defmodule HllConditionalActionsWeb.Plugs.StaleLoginFormTest do
  @moduledoc """
  A sign in form that outlived its session must land on a fresh form, not on a
  CSRF error page - and the protection itself must stay exactly as strict.

  `Phoenix.ConnTest` turns CSRF protection off for every request it builds, so
  the tests that are actually about tokens have to turn it back on with
  `enforcing_csrf/1`. Without that they would pass no matter what the plug did.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts

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

  defp enforcing_csrf(conn) do
    conn
    |> init_test_session(%{})
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
  end

  # The real browser flow: render the form, then post back the token that was
  # rendered into it.
  defp sign_in(conn, credentials) do
    conn = get(conn, ~p"/login")

    token =
      conn
      |> html_response(200)
      |> then(&Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, &1))
      |> Enum.at(1)

    conn
    |> recycle()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> post(~p"/login", Map.put(credentials, "_csrf_token", token))
  end

  describe "a form whose token no longer matches" do
    test "is answered with a fresh form instead of an error page", %{conn: conn} do
      conn =
        conn
        |> enforcing_csrf()
        |> post(~p"/login", %{
          "_csrf_token" => "a token from a session that is gone",
          "user" => %{"username" => "ana", "password" => "supersecret123"}
        })

      assert redirected_to(conn) == "/login?expired=1"
      refute get_session(conn, :user_id), "an expired form must not sign anyone in"
    end

    test "is answered the same way when the form carried no token", %{conn: conn} do
      conn =
        conn
        |> enforcing_csrf()
        |> post(~p"/login", %{"user" => %{"username" => "ana", "password" => "supersecret123"}})

      assert redirected_to(conn) == "/login?expired=1"
    end

    test "the fresh form explains what happened", %{conn: conn} do
      assert conn |> get(~p"/login?expired=1") |> html_response(200) =~ "open too long"
    end

    test "the plain form says nothing about it", %{conn: conn} do
      refute conn |> get(~p"/login") |> html_response(200) =~ "open too long"
    end
  end

  describe "a form with the token it was rendered with" do
    test "signs the visitor in", %{conn: conn} do
      conn = sign_in(conn, %{"user" => %{"username" => "ana", "password" => "supersecret123"}})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id)
    end

    test "still reports wrong credentials rather than an expired form", %{conn: conn} do
      conn = sign_in(conn, %{"user" => %{"username" => "ana", "password" => "nope"}})

      assert html_response(conn, 401) =~ "Wrong username or password"
    end
  end

  describe "the protection itself" do
    # The plug answers one path differently. Everywhere else a bad token must
    # still be refused outright, or this would have quietly weakened CSRF
    # protection across the whole app.
    test "other routes still reject a bad token", %{conn: conn} do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> enforcing_csrf()
        |> delete(~p"/logout", %{"_csrf_token" => "stale"})
      end
    end

    test "the sign in form is never cached, so the back button gets a live one", %{conn: conn} do
      assert conn |> get(~p"/login") |> get_resp_header("cache-control") == ["no-store"]
    end
  end

  test "the expired form is the whole form, hint included", %{conn: conn, user: user} do
    # `bootstrap!/0` only seeds the admin into an empty user table, so the
    # fixture from `setup` has to go first for this to be a first run at all.
    HllConditionalActions.Repo.delete!(user)
    :ok = Accounts.bootstrap!()

    response = conn |> get(~p"/login?expired=1") |> html_response(200)

    assert response =~ "open too long"
    # Matched by id rather than by its wording, which is presentation.
    assert response =~ ~s(id="first-run-hint")
    assert response =~ ~s(name="user[username]")
  end
end
