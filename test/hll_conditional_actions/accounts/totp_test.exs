defmodule HllConditionalActions.Accounts.TotpTest do
  @moduledoc """
  A second factor that computes the wrong code locks everybody out, and one
  that accepts too much is not a second factor. The RFC publishes test vectors
  for exactly this reason, so the first thing checked here is that this
  implementation agrees with them.
  """

  use ExUnit.Case, async: true

  alias HllConditionalActions.Accounts.Totp

  doctest Totp

  # RFC 6238, appendix B. The secret there is the ASCII "12345678901234567890";
  # the table gives the code every authenticator must produce at each time.
  @rfc_secret Base.encode32("12345678901234567890", padding: false)

  describe "against the RFC 6238 vectors" do
    test "produces the published codes" do
      for {unix_seconds, expected} <- [
            {59, "287082"},
            {1_111_111_109, "081804"},
            {1_111_111_111, "050471"},
            {1_234_567_890, "005924"},
            {2_000_000_000, "279037"},
            {20_000_000_000, "353130"}
          ] do
        assert Totp.code(@rfc_secret, div(unix_seconds, 30)) == expected,
               "wrong code at #{unix_seconds}"
      end
    end
  end

  describe "verify/3" do
    test "accepts the code for right now" do
      secret = Totp.generate_secret()

      assert {:ok, _step} = Totp.verify(secret, Totp.code(secret))
    end

    test "accepts one step either side, for clocks that disagree" do
      secret = Totp.generate_secret()
      now = div(System.system_time(:second), 30)

      # The step returned is the one the code belongs to, not the one the
      # server is in — that is what makes it usable as a replay marker.
      before = now - 1
      later = now + 1

      assert {:ok, ^before} = Totp.verify(secret, Totp.code(secret, before), now)
      assert {:ok, ^later} = Totp.verify(secret, Totp.code(secret, later), now)
    end

    test "refuses two steps away" do
      secret = Totp.generate_secret()
      now = div(System.system_time(:second), 30)

      assert Totp.verify(secret, Totp.code(secret, now - 2), now) == :error
      assert Totp.verify(secret, Totp.code(secret, now + 2), now) == :error
    end

    test "says which step it matched, so the caller can refuse a replay" do
      secret = Totp.generate_secret()
      now = div(System.system_time(:second), 30)

      assert {:ok, ^now} = Totp.verify(secret, Totp.code(secret, now), now)
    end

    test "refuses another account's code" do
      mine = Totp.generate_secret()
      theirs = Totp.generate_secret()

      assert Totp.verify(mine, Totp.code(theirs)) == :error
    end

    test "refuses anything that is not six digits" do
      secret = Totp.generate_secret()

      for nonsense <- ["", "12345", "1234567", "abcdef", "12 34 56 78"] do
        assert Totp.verify(secret, nonsense) == :error, "accepted #{inspect(nonsense)}"
      end
    end

    test "ignores the spaces an authenticator app puts in the middle" do
      secret = Totp.generate_secret()
      code = Totp.code(secret)
      spaced = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

      assert {:ok, _step} = Totp.verify(secret, spaced)
    end

    test "refuses a secret that is not valid base32 rather than crashing" do
      assert Totp.verify("not base 32 at all!", "123456") == :error
      assert Totp.verify(nil, "123456") == :error
    end
  end

  describe "generate_secret/0" do
    test "is base32 an authenticator can read back" do
      secret = Totp.generate_secret()

      assert {:ok, key} = Base.decode32(secret, padding: false)
      assert byte_size(key) == 20
    end

    test "is different every time" do
      secrets = for _each <- 1..50, do: Totp.generate_secret()

      assert secrets |> Enum.uniq() |> length() == 50
    end
  end

  describe "provisioning_uri/3" do
    test "carries everything an app needs to set itself up" do
      uri = Totp.provisioning_uri("ABCDEF", "sarge")

      assert uri =~ "otpauth://totp/"
      assert uri =~ "secret=ABCDEF"
      assert uri =~ "digits=6"
      assert uri =~ "period=30"
      assert uri =~ "algorithm=SHA1"
    end

    test "names the issuer in the label as well, because apps disagree" do
      uri = Totp.provisioning_uri("ABCDEF", "sarge", "My Clan")

      assert uri =~ "My%20Clan:sarge"
      assert uri =~ "issuer=My+Clan"
    end
  end

  test "readable_secret/1 groups the secret for typing by hand" do
    assert Totp.readable_secret("ABCDEFGHIJ") == "ABCD EFGH IJ"
  end

  test "a hand typed secret still verifies" do
    secret = Totp.generate_secret()

    assert {:ok, _step} = Totp.verify(Totp.readable_secret(secret), Totp.code(secret))
  end

  test "seconds_remaining/1 counts down within the step" do
    assert Totp.seconds_remaining(0) == 30
    assert Totp.seconds_remaining(29) == 1
    assert Totp.seconds_remaining(30) == 30
  end
end
