defmodule HllConditionalActionsWeb.PasswordChangeLiveTest do
  @moduledoc """
  "Troque a senha padrão": the new password, then the authenticator app.
  """

  use HllConditionalActionsWeb.ConnCase, async: true

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Sessions
  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.TwoFactor

  defp signed_in(conn, user) do
    {token, _session} = Sessions.create(user)
    init_test_session(conn, %{user_id: user.id, session_token: token})
  end

  defp new_password(view, password) do
    view
    |> form("#password-form", user: %{password: password, password_confirmation: password})
    |> render_submit()
  end

  test "the bootstrap account on its default password is warned", %{conn: conn} do
    :ok = Accounts.bootstrap!()
    admin = Accounts.get_user_by_username("admin")

    {:ok, view, _html} = conn |> signed_in(admin) |> live(~p"/account/password")

    assert has_element?(view, "#default-password-warning")
    assert has_element?(view, "#signed-in-as", "admin")
    assert has_element?(view, "#password-steps")
  end

  test "someone whose password an admin reset gets the plain notice", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})

    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    refute has_element?(view, "#default-password-warning")
    assert has_element?(view, "#password-required")
  end

  test "the checklist and the meter follow what is typed", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    view
    |> form("#password-form", user: %{password: "short", password_confirmation: ""})
    |> render_change()

    assert has_element?(view, "#password-strength .auth-meter--1")
    assert has_element?(view, "#password-rules .auth-rule--todo")

    view
    |> form("#password-form",
      user: %{password: "Longenough1234!!", password_confirmation: "Longenough1234!!"}
    )
    |> render_change()

    assert has_element?(view, "#password-strength .auth-meter--4")
    refute has_element?(view, "#password-rules .auth-rule--todo")
  end

  test "a password the policy refuses is not saved", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    new_password(view, "short1")

    assert has_element?(view, "#password-form .auth-error-text")
    assert Accounts.get_user(user.id).must_change_password?
  end

  test "saving leads to the authenticator, which can be turned on", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    new_password(view, "brandnewpass42")

    refute Accounts.get_user(user.id).must_change_password?
    assert has_element?(view, "#authenticator-setup svg")
    assert has_element?(view, "#authenticator-skip[href='/']")

    secret = HllConditionalActions.Accounts.Enrolments.pending(user).secret

    # The boxes fill a hidden field in the browser; here it is sent directly.
    view
    |> form("#authenticator-form")
    |> render_submit(%{"code" => Totp.code(secret)})

    assert has_element?(view, "#recovery-codes li")
    assert TwoFactor.enabled?(Accounts.get_user(user.id))
  end

  test "a wrong authenticator code says so", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})
    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    new_password(view, "brandnewpass42")

    view |> form("#authenticator-form") |> render_submit(%{"code" => "000000"})

    assert has_element?(view, "#authenticator-error")
    refute TwoFactor.enabled?(Accounts.get_user(user.id))
  end

  test "an account that already has two factor goes straight home", %{conn: conn} do
    user = user_fixture(%{must_change_password?: true})
    enrolment = TwoFactor.start_enrolment(user)
    {:ok, user, _codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

    {:ok, view, _html} = conn |> signed_in(user) |> live(~p"/account/password")

    refute has_element?(view, "#password-steps")

    assert {:error, {:live_redirect, %{to: "/"}}} = new_password(view, "brandnewpass42")
  end
end
