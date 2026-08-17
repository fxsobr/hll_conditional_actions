defmodule HllConditionalActionsWeb.ReleaseNotes do
  @moduledoc """
  Renders the Markdown GitHub returns with a release.

  Release notes arrive as text written by whoever cut the release, which means
  it is not ours and cannot be trusted into the page. Rather than add a
  Markdown library and then have to reason about which of its options let raw
  HTML through, this escapes everything first and then puts back the small
  set of shapes release notes actually use: headings, bullets, code, links,
  bold and italic.

  Anything outside that set survives as the literal text somebody typed, which
  is the failure a reader can understand.
  """

  @doc """
  Turn release notes into safe HTML.

  Always returns `{:safe, iodata}`, so it can be interpolated straight into a
  template.
  """
  def to_html(nil), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    html =
      markdown
      |> String.replace("\r\n", "\n")
      |> split_fences()
      |> Enum.map_join(&block/1)

    {:safe, html}
  end

  # Fenced code is taken out whole before anything else touches it, so a `#` or
  # a `*` inside a shell snippet stays what it is.
  defp split_fences(text) do
    text
    |> String.split(~r/^```[^\n]*\n(.*?)^```[ \t]*$/ms, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(~r/^```[^\n]*\n(.*?)^```[ \t]*$/ms, part) do
        [_whole, code] -> {:code, code}
        nil -> {:prose, part}
      end
    end)
  end

  defp block({:code, code}) do
    "<pre class=\"overflow-x-auto rounded-box bg-base-200 p-3 text-xs\"><code>" <>
      escape(String.trim_trailing(code)) <> "</code></pre>"
  end

  defp block({:prose, text}) do
    text
    |> String.split("\n")
    |> Enum.map(&line/1)
    |> group_list_items()
    |> Enum.join()
  end

  defp line(raw) do
    trimmed = String.trim_trailing(raw)
    indent = String.length(raw) - String.length(String.trim_leading(raw))

    cond do
      trimmed == "" ->
        :blank

      match = Regex.run(~r/^\s*[#]{1,6}\s+(.*)$/, trimmed) ->
        # Every heading level renders the same: inside a dialog there is no room
        # for a hierarchy, and release notes rarely mean one.
        {:html, "<p class=\"mt-3 text-title-small first:mt-0\">#{inline(Enum.at(match, 1))}</p>"}

      match = Regex.run(~r/^\s*(?:[-*+]|\d+\.)\s+(.*)$/, trimmed) ->
        {:item, indent, inline(Enum.at(match, 1))}

      true ->
        {:html, "<p class=\"mt-2 first:mt-0\">#{inline(trimmed)}</p>"}
    end
  end

  # Consecutive bullets become one list; an indented run becomes a nested one.
  defp group_list_items(lines) do
    {html, open} =
      Enum.reduce(lines, {[], 0}, fn
        :blank, {acc, open} ->
          {acc ++ close(open), 0}

        {:html, html}, {acc, open} ->
          {acc ++ close(open) ++ [html], 0}

        {:item, indent, content}, {acc, open} ->
          depth = min(div(indent, 2) + 1, 2)

          opened =
            cond do
              depth > open ->
                List.duplicate(~s(<ul class="ml-4 list-disc space-y-1">), depth - open)

              depth < open ->
                List.duplicate("</ul>", open - depth)

              true ->
                []
            end

          {acc ++ opened ++ ["<li>#{content}</li>"], depth}
      end)

    html ++ close(open)
  end

  defp close(open), do: List.duplicate("</ul>", open)

  # Inline markup, applied to text that is already escaped, so the only tags
  # in the result are the ones added here.
  defp inline(text) do
    text
    |> escape()
    |> String.replace(
      ~r/`([^`]+)`/,
      "<code class=\"rounded bg-base-200 px-1 text-xs\">\\1</code>"
    )
    |> String.replace(~r/\[([^\]]+)\]\((https?:[^)\s]+)\)/, link())
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/(?<![*\w])\*([^*\n]+)\*(?!\*)/, "<em>\\1</em>")
  end

  defp link do
    "<a href=\"\\2\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"link\">\\1</a>"
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
