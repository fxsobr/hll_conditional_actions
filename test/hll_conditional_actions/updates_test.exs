defmodule HllConditionalActions.UpdatesTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Updates

  describe "current_version/0" do
    test "reports what the build stamped in" do
      System.put_env("BUILD_VERSION", "v0.2.0-3-gab12cd3")
      on_exit(fn -> System.delete_env("BUILD_VERSION") end)

      assert Updates.current_version() == "v0.2.0-3-gab12cd3"
    end

    test "falls back to the mix.exs version when nothing stamped it" do
      System.delete_env("BUILD_VERSION")

      assert "v" <> rest = Updates.current_version()
      assert {:ok, _version} = Version.parse(rest)
    end

    test "an empty stamp counts as no stamp" do
      # A `docker build` with no --build-arg leaves the ARG empty rather than
      # unset, which would otherwise show as a blank version.
      System.put_env("BUILD_VERSION", "")
      on_exit(fn -> System.delete_env("BUILD_VERSION") end)

      assert "v" <> rest = Updates.current_version()
      assert {:ok, _version} = Version.parse(rest)
    end
  end

  describe "update_available?/2" do
    test "a higher release is an update" do
      assert Updates.update_available?("v0.1.0", %{tag: "v0.2.0"})
    end

    test "the same version is not" do
      refute Updates.update_available?("v0.1.0", %{tag: "v0.1.0"})
    end

    test "an older release is not" do
      refute Updates.update_available?("v0.2.0", %{tag: "v0.1.0"})
    end

    test "commits since the tag do not count as being behind" do
      # `git describe` on a commit past v0.1.0 reads v0.1.0-10-g5982d51. That
      # is ahead of the release, not behind it.
      refute Updates.update_available?("v0.1.0-10-g5982d51", %{tag: "v0.1.0"})
    end

    test "commits since the tag do not hide a real update either" do
      assert Updates.update_available?("v0.1.0-10-g5982d51", %{tag: "v0.2.0"})
    end

    test "no release means nothing to update to" do
      refute Updates.update_available?("v0.1.0", nil)
    end

    test "a version that is not semantic never claims an update" do
      # A build with no tags at all describes as a bare hash. Guessing at that
      # would mean telling an operator to upgrade on no evidence.
      refute Updates.update_available?("g5982d51", %{tag: "v9.9.9"})
      refute Updates.update_available?("v0.1.0", %{tag: "nightly"})
    end
  end

  describe "fetch_releases/0" do
    test "reads the tag, notes and date of each release" do
      Req.Test.stub(Updates, fn conn ->
        Req.Test.json(conn, [
          %{
            "tag_name" => "v0.2.0",
            "name" => "v0.2.0",
            "body" => "## Fixes\n- something",
            "html_url" => "https://github.com/fxsobr/hll_conditional_actions/releases/v0.2.0",
            "published_at" => "2026-08-16T20:13:00Z",
            "draft" => false,
            "prerelease" => false
          }
        ])
      end)

      assert {:ok, [release]} = Updates.fetch_releases()
      assert release.tag == "v0.2.0"
      assert release.notes == "## Fixes\n- something"
      assert release.published_at == ~U[2026-08-16 20:13:00Z]
    end

    test "drafts and pre-releases are left out" do
      Req.Test.stub(Updates, fn conn ->
        Req.Test.json(conn, [
          %{"tag_name" => "v0.3.0-rc1", "prerelease" => true, "draft" => false},
          %{"tag_name" => "v0.3.0", "prerelease" => false, "draft" => true},
          %{"tag_name" => "v0.2.0", "prerelease" => false, "draft" => false}
        ])
      end)

      assert {:ok, [release]} = Updates.fetch_releases()
      assert release.tag == "v0.2.0"
    end

    test "a repository with no releases yet is not an error" do
      Req.Test.stub(Updates, fn conn -> Req.Test.json(conn, []) end)

      assert {:ok, []} = Updates.fetch_releases()
    end

    test "a rate limit is reported rather than raised" do
      Req.Test.stub(Updates, fn conn -> Plug.Conn.send_resp(conn, 403, "rate limited") end)

      assert {:error, {:http, 403}} = Updates.fetch_releases()
    end

    test "an unreachable GitHub is reported rather than raised" do
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Updates.fetch_releases()
    end
  end

  describe "status/0" do
    test "answers before anything has been checked" do
      # The sidebar renders on the first request, which is well before the
      # first check has run.
      status = Updates.status()

      assert status.latest == nil
      assert status.releases == []
      refute status.update_available?
    end
  end
end
