defmodule HllConditionalActions.Accounts.TwoFactorTest do
  @moduledoc """
  Enrolling, verifying, and the two ways back in when the phone is gone.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Totp
  alias HllConditionalActions.Accounts.TwoFactor

  setup do
    %{user: user_fixture(%{username: "sarge"})}
  end

  describe "enrolling" do
    test "nothing is stored until a code confirms it", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)

      assert enrolment.secret =~ ~r/^[A-Z2-7]+$/
      assert enrolment.uri =~ "otpauth://totp/"
      assert enrolment.qr_svg =~ "<svg"

      # Reloaded from the database, the account is untouched.
      refute TwoFactor.enabled?(Accounts.get_user!(user.id))
    end

    test "a wrong code stores nothing", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)

      assert TwoFactor.confirm(user, enrolment.secret, "000000") == {:error, :invalid_code}
      refute TwoFactor.enabled?(Accounts.get_user!(user.id))
    end

    test "the right code turns it on and hands back recovery codes", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)

      assert {:ok, user, codes} =
               TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      assert TwoFactor.enabled?(user)
      assert length(codes) == 10
      assert Enum.all?(codes, &(&1 =~ ~r/^[a-f0-9]{5}-[a-f0-9]{5}$/))
    end

    test "the recovery codes are stored hashed, never in the clear", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      stored = Enum.join(user.totp_recovery_codes, " ")

      for code <- codes do
        refute stored =~ code
      end
    end

    test "the secret does not survive `inspect`", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, _codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      refute inspect(user) =~ enrolment.secret
    end
  end

  describe "verify/2 with a code from the app" do
    setup %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      %{user: user, secret: enrolment.secret, recovery_codes: codes}
    end

    test "accepts the current code", %{user: user, secret: secret} do
      # Confirming already burned this step, so the next one is the first that
      # can be used. That is the replay guard doing its job.
      next = div(System.system_time(:second), 30) + 1

      assert {:ok, _user} = TwoFactor.verify(user, Totp.code(secret, next))
    end

    test "refuses the same code twice", %{user: user, secret: secret} do
      next = div(System.system_time(:second), 30) + 1
      code = Totp.code(secret, next)

      assert {:ok, user} = TwoFactor.verify(user, code)
      assert TwoFactor.verify(user, code) == {:error, :invalid_code}
    end

    test "refuses a code from an older step, even one still inside the window", %{
      user: user,
      secret: secret
    } do
      next = div(System.system_time(:second), 30) + 1
      {:ok, user} = TwoFactor.verify(user, Totp.code(secret, next))

      assert TwoFactor.verify(user, Totp.code(secret, next - 1)) == {:error, :invalid_code}
    end

    test "refuses a wrong code", %{user: user} do
      assert TwoFactor.verify(user, "000000") == {:error, :invalid_code}
    end
  end

  describe "verify/2 with a recovery code" do
    setup %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      %{user: user, recovery_codes: codes}
    end

    test "accepts one, and says so", %{user: user, recovery_codes: [code | _rest]} do
      assert {:ok, _user, :recovery_code_used} = TwoFactor.verify(user, code)
    end

    test "spends it: the same one does not work twice", %{
      user: user,
      recovery_codes: [code | _rest]
    } do
      assert {:ok, user, :recovery_code_used} = TwoFactor.verify(user, code)
      assert TwoFactor.verify(user, code) == {:error, :invalid_code}
    end

    test "leaves the others alone", %{user: user, recovery_codes: [first, second | _rest]} do
      {:ok, user, :recovery_code_used} = TwoFactor.verify(user, first)

      assert {:ok, user, :recovery_code_used} = TwoFactor.verify(user, second)
      assert TwoFactor.recovery_codes_left(user) == 8
    end

    test "takes one typed without its dash, or in capitals", %{
      user: user,
      recovery_codes: [code | _rest]
    } do
      typed = code |> String.replace("-", "") |> String.upcase()

      assert {:ok, _user, :recovery_code_used} = TwoFactor.verify(user, typed)
    end

    test "refuses one belonging to somebody else", %{user: user} do
      other = user_fixture()
      enrolment = TwoFactor.start_enrolment(other)

      {:ok, _other, their_codes} =
        TwoFactor.confirm(other, enrolment.secret, Totp.code(enrolment.secret))

      assert TwoFactor.verify(user, hd(their_codes)) == {:error, :invalid_code}
    end
  end

  describe "regenerate_recovery_codes/1" do
    test "replaces the old ones", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, old} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      {:ok, user, new} = TwoFactor.regenerate_recovery_codes(user)

      assert length(new) == 10
      assert TwoFactor.verify(user, hd(old)) == {:error, :invalid_code}
      assert {:ok, _user, :recovery_code_used} = TwoFactor.verify(user, hd(new))
    end
  end

  describe "disable/1" do
    test "forgets everything, so a later enrolment starts clean", %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)
      {:ok, user, codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      {:ok, user} = TwoFactor.disable(user)

      refute TwoFactor.enabled?(user)
      assert is_nil(user.totp_secret)
      assert user.totp_recovery_codes == []
      assert TwoFactor.verify(user, hd(codes)) == {:error, :invalid_code}
    end
  end

  describe "enabled?/1" do
    test "is false for an account that never set it up", %{user: user} do
      refute TwoFactor.enabled?(user)
    end

    test "is false for a secret that was never confirmed", %{user: user} do
      # start_enrolment stores nothing, so this is the state a person who
      # closed the page halfway leaves behind.
      TwoFactor.start_enrolment(user)

      refute TwoFactor.enabled?(Accounts.get_user!(user.id))
    end

    test "handles nil, for the anonymous case" do
      refute TwoFactor.enabled?(nil)
    end
  end

  test "enabled_user_ids/0 lists only the confirmed ones", %{user: user} do
    _without = user_fixture()
    enrolment = TwoFactor.start_enrolment(user)
    {:ok, user, _codes} = TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

    ids = TwoFactor.enabled_user_ids()

    assert MapSet.member?(ids, user.id)
    assert MapSet.size(ids) == 1
  end

  describe "verify_step_up/2" do
    setup %{user: user} do
      enrolment = TwoFactor.start_enrolment(user)

      {:ok, user, codes} =
        TwoFactor.confirm(user, enrolment.secret, Totp.code(enrolment.secret))

      HllConditionalActions.RateLimit.reset(TwoFactor.attempt_key(user))

      on_exit(fn -> HllConditionalActions.RateLimit.reset(TwoFactor.attempt_key(user)) end)

      %{user: user, secret: enrolment.secret, recovery_codes: codes}
    end

    test "accepts a code from the app", %{user: user, secret: secret} do
      next = div(System.system_time(:second), 30) + 1

      assert {:ok, _user} = TwoFactor.verify_step_up(user, Totp.code(secret, next))
    end

    test "accepts a recovery code, and spends it", %{
      user: user,
      recovery_codes: [code | _rest]
    } do
      assert {:ok, user} = TwoFactor.verify_step_up(user, code)
      assert TwoFactor.recovery_codes_left(user) == 9
    end

    test "refuses a wrong code", %{user: user} do
      assert TwoFactor.verify_step_up(user, "000000") == {:error, :invalid_code}
    end

    test "counts wrong codes against the sign in budget", %{user: user} do
      previous = Application.get_env(:hll_conditional_actions, :two_factor_rate_limit)

      Application.put_env(:hll_conditional_actions, :two_factor_rate_limit,
        limit: 2,
        window_ms: 900_000
      )

      on_exit(fn ->
        Application.put_env(:hll_conditional_actions, :two_factor_rate_limit, previous)
      end)

      assert TwoFactor.verify_step_up(user, "000000") == {:error, :invalid_code}
      assert TwoFactor.verify_step_up(user, "000000") == {:error, :invalid_code}

      # The account page must not be a fresh budget for guessing: this is the
      # same counter the sign in prompt spends.
      assert {:error, :rate_limited, _seconds} = TwoFactor.verify_step_up(user, "000000")
    end

    test "a right code clears the count", %{user: user, secret: secret} do
      TwoFactor.verify_step_up(user, "000000")
      next = div(System.system_time(:second), 30) + 1

      assert {:ok, user} = TwoFactor.verify_step_up(user, Totp.code(secret, next))

      assert HllConditionalActions.RateLimit.count(TwoFactor.attempt_key(user), 900_000) == 0
    end
  end
end
