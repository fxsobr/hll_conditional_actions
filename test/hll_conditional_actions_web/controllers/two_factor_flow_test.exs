defmodule HllConditionalActionsWeb.TwoFactorFlowTest do
  @moduledoc """
  Signing in when the account has a second factor.

  The thing worth proving here is the negative: that a browser which has given
  the right password and nothing else can reach no page at all.
  """

  use HllConditionalActionsWeb.ConnCase, async: false

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.RateLimit

  setup do
    previous = Application.get_env(:hll_conditional_actions, :two_factor_rate_limit)

    on_exit(fn ->
      Application.put_env(:hll_conditional_actions, :two_factor_rate_limit, previous)
    end)

    user =
      user_fixture(%{
        username: "sarge",
        password: "wintergreen1",
        password_confirmation: "wintergreen1"
      })

    enrolment = TwoFactor.start_enrolment(user)

    {:ok, user, recovery_codes} =
      TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

    RateLimit.reset("2fa:user:#{user.id}")

    %{user: user, secret: enrolment.secret, recovery_codes: recovery_codes}
  end

  defp sign_in_with_password(conn) do
    post(conn, ~p"/login", %{"user" => %{"username" => "sarge", "password" => "wintergreen1"}})
  end

  defp next_code(secret), do: Totp.code(secret, div(System.system_time(:second), 30) + 1)

  describe "the password step" do
    test "stops at the code prompt instead of signing in", %{conn: conn} do
      conn = sign_in_with_password(conn)

      assert redirected_to(conn) == ~p"/login/code"
    end

    test "does not sign anybody in", %{conn: conn} do
      conn = sign_in_with_password(conn)

      # Following it to any real page bounces back to the login form.
      assert conn |> recycle() |> get(~p"/") |> redirected_to() == ~p"/login"
    end

    test "a wrong password never reaches the code prompt", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"user" => %{"username" => "sarge", "password" => "no"}})

      assert html_response(conn, 401) =~ "Wrong username or password"
    end
  end

  describe "the code step" do
    test "the right code finishes signing in", %{conn: conn, secret: secret} do
      conn = conn |> sign_in_with_password() |> recycle()
      conn = post(conn, ~p"/login/code", %{"code" => next_code(secret)})

      assert redirected_to(conn) == ~p"/"
      assert conn |> recycle() |> get(~p"/") |> html_response(200)
    end

    test "a wrong code does not", %{conn: conn} do
      conn = conn |> sign_in_with_password() |> recycle()
      conn = post(conn, ~p"/login/code", %{"code" => "000000"})

      assert html_response(conn, 401) =~ "That code is not right"
      assert conn |> recycle() |> get(~p"/") |> redirected_to() == ~p"/login"
    end

    test "a recovery code works, and says how many are left", %{
      conn: conn,
      recovery_codes: [code | _rest]
    } do
      conn = conn |> sign_in_with_password() |> recycle()
      conn = post(conn, ~p"/login/code", %{"code" => code})

      assert redirected_to(conn) == ~p"/"

      # The greeting must not bury this: one info flash survives, and the
      # count of what is left is the half that matters.
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "recovery code"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "9"
    end

    test "the prompt cannot be opened without giving a password first", %{conn: conn} do
      assert conn |> get(~p"/login/code") |> redirected_to() == ~p"/login"
    end

    test "posting a code without giving a password first is refused", %{
      conn: conn,
      secret: secret
    } do
      conn = post(conn, ~p"/login/code", %{"code" => next_code(secret)})

      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "the code page" do
    test "shows six boxes, who is signing in and how long the code lasts", %{conn: conn} do
      conn = conn |> sign_in_with_password() |> recycle()
      html = conn |> get(~p"/login/code") |> html_response(200) |> LazyHTML.from_document()

      assert html |> LazyHTML.query("#two-factor-digits input[data-digit]") |> Enum.count() == 6
      # The boxes fill one hidden field, under the name the controller reads.
      assert html
             |> LazyHTML.query("#two-factor-form input[type=hidden][name=code]")
             |> Enum.count() == 1

      assert html |> LazyHTML.query("#two-factor-timer [data-count]") |> Enum.count() == 1
      assert LazyHTML.text(html) =~ "sarge"
      assert html |> LazyHTML.query("#code-steps li") |> Enum.count() == 3
      assert html |> LazyHTML.query("#two-factor-back[href='/login']") |> Enum.count() == 1
      assert html |> LazyHTML.query("#use-recovery-code") |> Enum.count() == 1
    end

    test "can switch to a single recovery code field, which signs in", %{
      conn: conn,
      recovery_codes: [code | _rest]
    } do
      conn = conn |> sign_in_with_password() |> recycle()

      html =
        conn |> get(~p"/login/code?recovery=1") |> html_response(200) |> LazyHTML.from_document()

      assert html |> LazyHTML.query("input#two_factor_code[name=code][type=text]") |> Enum.count() ==
               1

      assert html |> LazyHTML.query("#two-factor-digits") |> Enum.count() == 0
      assert html |> LazyHTML.query("#use-app-code") |> Enum.count() == 1

      assert conn
             |> post(~p"/login/code", %{"code" => code, "mode" => "recovery"})
             |> redirected_to() ==
               ~p"/"
    end

    test "a wrong recovery code keeps the recovery field", %{conn: conn} do
      conn = conn |> sign_in_with_password() |> recycle()

      response =
        conn
        |> post(~p"/login/code", %{"code" => "nope-nope", "mode" => "recovery"})
        |> html_response(401)

      assert response =~ ~s(id="two-factor-error")
      assert response =~ ~s(name="mode")
      refute response =~ ~s(id="two-factor-digits")
    end
  end

  describe "throttling the code step" do
    setup %{user: user} do
      Application.put_env(:hll_conditional_actions, :two_factor_rate_limit,
        limit: 3,
        window_ms: 900_000
      )

      on_exit(fn -> RateLimit.reset("2fa:user:#{user.id}") end)

      :ok
    end

    test "stops answering after a few wrong codes", %{conn: conn} do
      conn = conn |> sign_in_with_password() |> recycle()

      for _attempt <- 1..3 do
        assert conn |> post(~p"/login/code", %{"code" => "000000"}) |> Map.fetch!(:status) == 401
      end

      refused = post(conn, ~p"/login/code", %{"code" => "000000"})

      assert refused.status == 429
      assert [_retry_after] = get_resp_header(refused, "retry-after")
    end

    test "the right code still works below the limit, and clears the count", %{
      conn: conn,
      secret: secret,
      user: user
    } do
      conn = conn |> sign_in_with_password() |> recycle()
      post(conn, ~p"/login/code", %{"code" => "000000"})

      assert conn |> post(~p"/login/code", %{"code" => next_code(secret)}) |> redirected_to() ==
               ~p"/"

      assert RateLimit.count("2fa:user:#{user.id}", 900_000) == 0
    end
  end

  describe "an account without a second factor" do
    test "signs in on the password alone", %{conn: conn} do
      user_fixture(%{
        username: "plain",
        password: "wintergreen1",
        password_confirmation: "wintergreen1"
      })

      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "plain", "password" => "wintergreen1"}})

      assert redirected_to(conn) == ~p"/"
    end
  end
end
