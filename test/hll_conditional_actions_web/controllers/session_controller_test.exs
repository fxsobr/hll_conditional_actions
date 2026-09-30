defmodule HllConditionalActionsWeb.SessionControllerTest do
  use HllConditionalActionsWeb.ConnCase, async: true
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.PasswordReset
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.Workers.SendPasswordResetEmail
  alias HllConditionalActionsWeb.ResetPasswordLive

  describe "GET /login" do
    test "renders the form", %{conn: conn} do
      conn = get(conn, ~p"/login")

      response = html_response(conn, 200)
      assert response =~ "Sign in"
      # The screenshot tool and password managers sign in through these.
      assert response =~ ~s(id="login-form")
      assert response =~ ~s(id="user_username")
      assert response =~ ~s(name="user[password]")
    end

    test "shows the steps, the language switch, the map and the version", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200) |> LazyHTML.from_document()

      assert html |> LazyHTML.query("#login-steps li") |> Enum.count() == 3
      assert html |> LazyHTML.query("#auth-lang a") |> Enum.count() >= 2
      assert html |> LazyHTML.query("#forgot-link[href='/login?forgot=1']") |> Enum.count() == 1

      assert html
             |> LazyHTML.query("img[src='/images/maps/hll/hill400-dusk.webp']")
             |> Enum.count() == 1

      assert LazyHTML.text(LazyHTML.query(html, ".auth-foot")) =~ ~r/v\d/
    end

    test "the only button in the form is the one that signs in", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200) |> LazyHTML.from_document()

      assert [_submit] = html |> LazyHTML.query("#login-form button") |> Enum.to_list()
      assert html |> LazyHTML.query("#login-form button[type=submit]") |> Enum.count() == 1
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
      assert response =~ ~s(id="login-error")
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

  # ── Esqueci a senha ─────────────────────────────────────────────────────────

  defp configure_mail do
    {:ok, _settings} =
      VipShop.update_settings(:email, %{
        "email_provider" => "smtp",
        "smtp_host" => "smtp.example.com",
        "mail_from_address" => "noreply@example.com"
      })

    :ok
  end

  defp reset_user(attrs \\ %{}) do
    user_fixture(
      Map.merge(
        %{
          username: "carla#{System.unique_integer([:positive])}",
          email: "carla#{System.unique_integer([:positive])}@example.com",
          password: "oldpassword123",
          password_confirmation: "oldpassword123"
        },
        attrs
      )
    )
  end

  describe "asking for a reset link" do
    test "without a mail server the page says so instead of pretending", %{conn: conn} do
      response = conn |> get(~p"/login?forgot=1") |> html_response(200)

      assert response =~ ~s(id="reset-no-mail")
      refute response =~ ~s(id="reset-request-form")
    end

    test "with a mail server it asks for the e-mail", %{conn: conn} do
      :ok = configure_mail()

      response = conn |> get(~p"/login?forgot=1") |> html_response(200)

      assert response =~ ~s(id="reset-request-form")
      assert response =~ ~s(name="reset[email]")
      refute response =~ ~s(id="reset-no-mail")
    end

    test "sends a link to the account with that address", %{conn: conn} do
      :ok = configure_mail()
      user = reset_user()

      response =
        conn
        |> post(~p"/login", %{"reset" => %{"email" => String.upcase(user.email)}})
        |> html_response(200)

      assert response =~ ~s(id="reset-sent")
      assert response =~ PasswordReset.mask(user.email)
      assert response =~ ~s(id="reset-resend")

      assert_enqueued(worker: SendPasswordResetEmail, args: %{"user_id" => user.id})

      [job] = all_enqueued(worker: SendPasswordResetEmail)
      assert :ok = perform_job(SendPasswordResetEmail, job.args)

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.text_body =~ "/login?reset_token="
      end)
    end

    test "says the same thing for an address nobody has, and sends nothing", %{conn: conn} do
      :ok = configure_mail()

      response =
        conn
        |> post(~p"/login", %{"reset" => %{"email" => "nobody@example.com"}})
        |> html_response(200)

      assert response =~ ~s(id="reset-sent")
      refute_enqueued(worker: SendPasswordResetEmail)
    end

    test "an inactive account gets nothing", %{conn: conn} do
      :ok = configure_mail()
      user = reset_user(%{active: false})

      conn |> post(~p"/login", %{"reset" => %{"email" => user.email}}) |> html_response(200)

      refute_enqueued(worker: SendPasswordResetEmail)
    end

    test "asking over and over stops sending, without saying so", %{conn: conn} do
      :ok = configure_mail()
      user = reset_user()

      for _attempt <- 1..5 do
        assert conn
               |> post(~p"/login", %{"reset" => %{"email" => user.email}})
               |> html_response(200) =~ ~s(id="reset-sent")
      end

      assert length(all_enqueued(worker: SendPasswordResetEmail)) == 3
    end

    test "without a mail server posting the form says so", %{conn: conn} do
      reset_user(%{email: "someone@example.com"})

      response =
        conn
        |> post(~p"/login", %{"reset" => %{"email" => "someone@example.com"}})
        |> html_response(200)

      assert response =~ ~s(id="reset-no-mail")
      refute_enqueued(worker: SendPasswordResetEmail)
    end
  end

  describe "the link" do
    test "opens the new password form", %{conn: conn} do
      user = reset_user()
      token = PasswordReset.token(user)

      response = conn |> get(~p"/login?#{[reset_token: token]}") |> html_response(200)

      assert response =~ ~s(id="reset-password-form")
      assert response =~ user.username

      assert get_resp_header(
               get(build_conn(), ~p"/login?#{[reset_token: token]}"),
               "referrer-policy"
             ) ==
               ["no-referrer"]
    end

    test "a forged or expired link is refused", %{conn: conn} do
      user = reset_user()
      old = PasswordReset.token(user, signed_at: System.system_time(:second) - 31 * 60)

      for token <- ["nonsense", old] do
        response = conn |> get(~p"/login?#{[reset_token: token]}") |> html_response(200)

        assert response =~ ~s(id="reset-error")
        refute response =~ ~s(id="reset-password-form")
      end
    end

    test "sets the new password once, and signs the old sessions out", %{conn: conn} do
      user = reset_user()
      {_token, _session} = Accounts.Sessions.create(user)
      token = PasswordReset.token(user)

      conn =
        post(conn, ~p"/login", %{
          "reset_password" => %{
            "token" => token,
            "password" => "brandnewpass42",
            "password_confirmation" => "brandnewpass42"
          }
        })

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password changed"
      assert {:ok, _user} = Accounts.authenticate(user.username, "brandnewpass42")
      assert Accounts.Sessions.list(user) == []

      # The link dies with the password it was issued for.
      response = build_conn() |> get(~p"/login?#{[reset_token: token]}") |> html_response(200)
      assert response =~ ~s(id="reset-error")
    end

    test "a password the policy refuses keeps the link alive", %{conn: conn} do
      user = reset_user()
      token = PasswordReset.token(user)

      conn =
        post(conn, ~p"/login", %{
          "reset_password" => %{
            "token" => token,
            "password" => "short1",
            "password_confirmation" => "short1"
          }
        })

      assert html_response(conn, 422) =~ ~s(id="reset-password-form")
      assert {:ok, _user} = PasswordReset.verify(token)
      assert {:ok, _user} = Accounts.authenticate(user.username, "oldpassword123")
    end

    test "the form ticks the checklist off as the password is typed", %{conn: conn} do
      user = reset_user()

      {:ok, view, _html} =
        live_isolated(conn, ResetPasswordLive, session: %{"token" => PasswordReset.token(user)})

      assert has_element?(view, "#reset-rules .auth-rule--todo")

      view
      |> form("#reset-password-form",
        reset_password: %{password: "Longenough1234!!", password_confirmation: "Longenough1234!!"}
      )
      |> render_change()

      refute has_element?(view, "#reset-rules .auth-rule--todo")
      assert has_element?(view, "#reset-strength .auth-meter--4")
    end
  end
end
