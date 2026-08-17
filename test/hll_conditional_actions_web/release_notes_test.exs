defmodule HllConditionalActionsWeb.ReleaseNotesTest do
  use ExUnit.Case, async: true

  alias HllConditionalActionsWeb.ReleaseNotes

  defp render(markdown) do
    markdown |> ReleaseNotes.to_html() |> Phoenix.HTML.safe_to_string()
  end

  describe "the markdown release notes use" do
    test "headings become a line of their own" do
      assert render("## Bug Fixes") =~ "Bug Fixes"
      refute render("## Bug Fixes") =~ "##"
    end

    test "bullets become a list" do
      html = render("- first\n- second")

      assert html =~ "<ul"
      assert html =~ "<li>first</li>"
      assert html =~ "<li>second</li>"
    end

    test "an indented bullet nests" do
      html = render("- first\n  - nested")

      assert html =~ "<li>nested</li>"
      # Opened twice, closed twice.
      assert length(String.split(html, "<ul")) == 3
      assert length(String.split(html, "</ul>")) == 3
    end

    test "a fenced block keeps its contents verbatim" do
      html = render("Upgrade:\n\n```\ngit fetch --tags\ngit checkout v0.2.0\n```")

      assert html =~ "<pre"
      assert html =~ "git checkout v0.2.0"
      # `--tags` inside a fence is text, not markup.
      assert html =~ "git fetch --tags"
    end

    test "bold, italic, inline code and links" do
      assert render("**loud**") =~ "<strong>loud</strong>"
      assert render("*quiet*") =~ "<em>quiet</em>"
      assert render("`mix test`") =~ "<code"
      assert render("[the wiki](https://example.com/w)") =~ ~S|href="https://example.com/w"|
    end

    test "a link opens away from the app" do
      html = render("[the wiki](https://example.com/w)")

      assert html =~ ~S|rel="noopener noreferrer"|
      assert html =~ ~S|target="_blank"|
    end

    test "nothing at all renders as nothing" do
      assert render(nil) == ""
      assert render("") == ""
    end
  end

  describe "release notes are somebody else's text" do
    test "a script tag in the notes is shown, not run" do
      html = render("Careful: <script>alert('xss')</script>")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "an img with an onerror handler is escaped" do
      html = render(~S|<img src=x onerror="alert(1)">|)

      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "a javascript: link does not become a link" do
      # Only http and https are turned into anchors, so the scheme cannot be
      # smuggled through the markdown link syntax.
      html = render("[click](javascript:alert(1))")

      refute html =~ "<a href"
      assert html =~ "javascript:alert(1)"
    end

    test "a quote inside a link cannot break out of the attribute" do
      html = render(~S|[x](https://example.com/"onmouseover="alert(1))|)

      refute html =~ ~S|onmouseover="|
    end

    test "html inside a fenced block is escaped too" do
      html = render("```\n<script>alert('xss')</script>\n```")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
