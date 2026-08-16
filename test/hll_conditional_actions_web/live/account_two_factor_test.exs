defmodule HllConditionalActionsWeb.AccountTwoFactorTest do
  @moduledoc """
  The account page's second factor card.

  What matters here is what a session alone cannot do. Turning two factor off
  and replacing the recovery codes both weaken the account, so a stolen cookie
  or a borrowed laptop must not be enough — and the test that proves it is the
  one that pushes the events straight at the LiveView, bypassing every button.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.TwoFactor
  alias HllConditionalActions.RateLimit

  setup %{conn: conn} do
    user = user_fixture()

    enrolment = TwoFactor.start_enrolment(user)
    {:ok, user, codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

    RateLimit.reset(TwoFactor.attempt_key(user))
    on_exit(fn -> RateLimit.reset(TwoFactor.attempt_key(user)) end)

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, user: user, secret: enrolment.secret, recovery_codes: codes}
  end

  defp next_code(secret), do: Totp.code(secret, div(System.system_time(:second), 30) + 1)

  defp reload(user), do: Accounts.get_user!(user.id)

  describe "turning it off" do
    test "asking does not turn it off by itself", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_disable")

      assert TwoFactor.enabled?(reload(user))
    end

    test "a code turns it off", %{conn: conn, user: user, secret: secret} do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_disable")
      render_submit(view, "confirm_step_up", %{"code" => next_code(secret)})

      refute TwoFactor.enabled?(reload(user))
    end

    test "a wrong code does not", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_disable")
      html = render_submit(view, "confirm_step_up", %{"code" => "000000"})

      assert html =~ "not right"
      assert TwoFactor.enabled?(reload(user))
    end

    test "a recovery code counts as proof", %{
      conn: conn,
      user: user,
      recovery_codes: [code | _rest]
    } do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_disable")
      render_submit(view, "confirm_step_up", %{"code" => code})

      refute TwoFactor.enabled?(reload(user))
    end
  end

  describe "replacing the recovery codes" do
    test "asking does not replace them", %{conn: conn, user: user, recovery_codes: codes} do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_regenerate")

      # The old ones still work, so nothing was replaced.
      assert {:ok, _user, :recovery_code_used} = TwoFactor.verify(reload(user), hd(codes))
    end

    test "a code replaces them, and the new ones are shown once", %{
      conn: conn,
      user: user,
      secret: secret,
      recovery_codes: codes
    } do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_regenerate")
      html = render_submit(view, "confirm_step_up", %{"code" => next_code(secret)})

      assert html =~ "Write these down now"
      assert TwoFactor.verify(reload(user), hd(codes)) == {:error, :invalid_code}
    end

    test "a wrong code leaves the old ones alone", %{
      conn: conn,
      user: user,
      recovery_codes: codes
    } do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_regenerate")
      render_submit(view, "confirm_step_up", %{"code" => "000000"})

      assert {:ok, _user, :recovery_code_used} = TwoFactor.verify(reload(user), hd(codes))
    end
  end

  describe "the events themselves" do
    test "confirming with nothing pending changes nothing", %{
      conn: conn,
      user: user,
      secret: secret
    } do
      {:ok, view, _html} = live(conn, ~p"/account")

      # A right code, but no action was asked for. It must do nothing at all —
      # not switch two factor off, and not crash the page either.
      render_submit(view, "confirm_step_up", %{"code" => next_code(secret)})

      assert TwoFactor.enabled?(reload(user))
      assert render(view) =~ "Two factor"
    end

    test "cancelling drops the pending action", %{conn: conn, user: user, secret: secret} do
      {:ok, view, _html} = live(conn, ~p"/account")

      render_click(view, "ask_disable")
      render_click(view, "cancel_step_up")

      render_submit(view, "confirm_step_up", %{"code" => next_code(secret)})

      assert TwoFactor.enabled?(reload(user))
    end
  end
end
