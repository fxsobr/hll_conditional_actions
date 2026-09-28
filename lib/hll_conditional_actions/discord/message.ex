defmodule HllConditionalActions.Discord.Message do
  @moduledoc """
  Turns the parameters of a `send_discord_webhook` action into the JSON body
  Discord's "execute webhook" endpoint takes.

  Rendering is passed in as a function, so the engine renders against a live
  context, the builder's preview against nothing (placeholders stay visible)
  and an aggregated sweep once per player.

  Everything Discord would reject is fixed here rather than discovered as a
  400: text is cut to Discord's limits, a blank field gets an invisible
  character, and mentions are off unless the rule lists the roles it may ping.
  """

  # Discord's documented limits.
  @content_limit 2000
  @title_limit 256
  @description_limit 4096
  @field_name_limit 256
  @field_value_limit 1024
  @field_count_limit 25
  @footer_limit 2048
  @username_limit 80
  @embed_total_limit 6000

  @ellipsis "…"
  # Discord refuses empty field names and values; this renders as nothing.
  @blank "​"

  # MessageFlags.SUPPRESS_NOTIFICATIONS: posted without a push or sound.
  @silent_flag 4096

  @type payload :: %{String.t() => term()}
  @type render :: (String.t() | nil -> String.t())

  @doc """
  Builds the payload.

  ## Options

    * `:lines` - in an aggregated sweep, the per-player renderings of the
      message. They replace `content`, or extend the embed's description when
      the action has an embed.
  """
  @spec build(map(), render(), keyword()) :: payload()
  def build(params, render, opts \\ []) do
    lines = Keyword.get(opts, :lines)
    embed = embed(params, render)
    body = body(params, render, lines, embed)

    %{
      "content" => body.content,
      "embeds" => if(body.embed, do: [body.embed], else: []),
      "allowed_mentions" => %{"parse" => [], "roles" => role_ids(params["mention_role_ids"])},
      "username" => present(render.(params["username"])),
      "avatar_url" => present(params["avatar_url"]),
      "flags" => if(truthy?(params["silent"]), do: @silent_flag)
    }
    |> reject_nil()
    |> limit()
  end

  defp body(_params, _render, lines, embed) when is_list(lines) do
    text = Enum.join(lines, "\n")

    case embed do
      nil -> %{content: present(text), embed: nil}
      embed -> %{content: nil, embed: append_description(embed, text)}
    end
  end

  defp body(params, render, nil, embed) do
    %{content: present(render.(params["message"])), embed: embed}
  end

  defp append_description(embed, ""), do: embed

  defp append_description(embed, text) do
    Map.update(embed, "description", text, &(&1 <> "\n\n" <> text))
  end

  @doc """
  Whether a payload has anything for Discord to show.
  """
  @spec empty?(payload()) :: boolean()
  def empty?(payload), do: blank?(payload["content"]) and payload["embeds"] in [nil, []]

  @doc """
  A one line account of a payload, for the history and the simulation.

      iex> HllConditionalActions.Discord.Message.summary(%{"content" => "Hi", "embeds" => [%{"title" => "Ban"}]})
      "Hi | Ban"
  """
  @spec summary(payload()) :: String.t()
  def summary(payload) do
    embed = List.first(payload["embeds"] || []) || %{}

    [payload["content"], embed["title"], embed["description"]]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  # ── Embed ──────────────────────────────────────────────────────────────────

  defp embed(params, render) do
    embed =
      %{
        "title" => present(render.(params["embed_title"])),
        "description" => present(render.(params["embed_description"])),
        "fields" => fields(params["embed_fields"], render),
        "footer" => wrap(present(render.(params["embed_footer"])), "text"),
        "thumbnail" => wrap(present(params["embed_thumbnail_url"]), "url")
      }
      |> reject_nil()
      |> Map.reject(fn {_key, value} -> value == [] end)

    if embed == %{} do
      nil
    else
      embed
      |> Map.put("color", color(params["embed_color"]))
      |> Map.put("timestamp", if(truthy?(params["embed_timestamp"]), do: now()))
      |> reject_nil()
    end
  end

  @doc """
  Reads embed fields written one per line as `Name | Value`. A line without
  a bar is a value with no name.

      iex> HllConditionalActions.Discord.Message.parse_fields("Kills | {kills}\\nNo name")
      [{"Kills", "{kills}"}, {"", "No name"}]
  """
  @spec parse_fields(String.t() | nil) :: [{String.t(), String.t()}]
  def parse_fields(nil), do: []

  def parse_fields(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&blank?/1)
    |> Enum.map(fn line ->
      case String.split(line, "|", parts: 2) do
        [name, value] -> {String.trim(name), String.trim(value)}
        [value] -> {"", String.trim(value)}
      end
    end)
  end

  # Split before rendering, so a bar in a player's name cannot move text from
  # the value into the name.
  defp fields(text, render) do
    text
    |> parse_fields()
    |> Enum.map(fn {name, value} ->
      %{
        "name" => fill(render.(name)),
        "value" => fill(render.(value)),
        "inline" => true
      }
    end)
  end

  defp wrap(nil, _key), do: nil
  defp wrap(value, key), do: %{key => value}

  defp fill(text), do: if(blank?(text), do: @blank, else: text)

  @doc """
  Reads a `#RRGGBB` colour as the integer Discord expects.

      iex> HllConditionalActions.Discord.Message.color("#E74C3C")
      15158332

      iex> HllConditionalActions.Discord.Message.color("red")
      nil
  """
  @spec color(String.t() | nil) :: integer() | nil
  def color("#" <> hex) when byte_size(hex) == 6 do
    case Integer.parse(hex, 16) do
      {value, ""} -> value
      _other -> nil
    end
  end

  def color(_value), do: nil

  @doc """
  The role ids a rule may ping, from a list typed with any separator.

      iex> HllConditionalActions.Discord.Message.role_ids("<@&123456789012345678>, 223456789012345678")
      ["123456789012345678", "223456789012345678"]
  """
  @spec role_ids(String.t() | nil) :: [String.t()]
  def role_ids(nil), do: []

  def role_ids(text) when is_binary(text) do
    ~r/\d{15,25}/ |> Regex.scan(text) |> List.flatten() |> Enum.uniq() |> Enum.take(100)
  end

  # ── Limits ─────────────────────────────────────────────────────────────────

  @doc """
  Cuts a payload to what Discord accepts.
  """
  @spec limit(payload()) :: payload()
  def limit(payload) do
    payload
    |> update_present("content", &truncate(&1, @content_limit))
    |> update_present("username", &truncate(&1, @username_limit))
    |> update_present("embeds", fn embeds -> Enum.map(embeds, &limit_embed/1) end)
  end

  defp limit_embed(embed) do
    embed =
      embed
      |> update_present("title", &truncate(&1, @title_limit))
      |> update_present("description", &truncate(&1, @description_limit))
      |> update_present("footer", fn footer ->
        Map.update!(footer, "text", &truncate(&1, @footer_limit))
      end)
      |> update_present("fields", fn fields ->
        fields
        |> Enum.take(@field_count_limit)
        |> Enum.map(fn field ->
          %{
            field
            | "name" => truncate(field["name"], @field_name_limit),
              "value" => truncate(field["value"], @field_value_limit)
          }
        end)
      end)

    fit_total(embed)
  end

  # The 6000 characters are shared by every text of the embed. The
  # description gives way first, then the last fields go, one at a time.
  defp fit_total(embed) do
    excess = embed_length(embed) - @embed_total_limit

    cond do
      excess <= 0 ->
        embed

      String.length(embed["description"] || "") > 1 ->
        description = embed["description"]
        keep = max(String.length(description) - excess, 1)
        fit_total(Map.put(embed, "description", truncate(description, keep)))

      (embed["fields"] || []) != [] ->
        fit_total(Map.update!(embed, "fields", &Enum.drop(&1, -1)))

      true ->
        embed
    end
  end

  defp embed_length(embed) do
    texts =
      [embed["title"], embed["description"], get_in(embed, ["footer", "text"])] ++
        Enum.flat_map(embed["fields"] || [], &[&1["name"], &1["value"]])

    texts |> Enum.reject(&is_nil/1) |> Enum.map(&String.length/1) |> Enum.sum()
  end

  @doc """
  Cuts `text` to `limit` characters, marking the cut.

      iex> HllConditionalActions.Discord.Message.truncate("abcdef", 4)
      "abc…"
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, limit) do
    if String.length(text) > limit do
      String.slice(text, 0, limit - 1) <> @ellipsis
    else
      text
    end
  end

  # ── Markdown ───────────────────────────────────────────────────────────────

  @doc """
  Escapes Discord markdown in a value that came from a player, so a name like
  `**x**` shows as typed instead of bold, and `<@123>` does not look like a
  mention.

      iex> HllConditionalActions.Discord.Message.escape_markdown("*Ana*_ <@1>")
      "\\\\*Ana\\\\*\\\\_ \\\\<@1\\\\>"
  """
  @spec escape_markdown(String.t() | nil) :: String.t() | nil
  def escape_markdown(nil), do: nil

  def escape_markdown(text) when is_binary(text) do
    String.replace(text, ~r/[\\*_~`|>#\-\[\]()<:]/, "\\\\\\0")
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp update_present(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> Map.put(map, key, fun.(value))
      _missing -> map
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp blank?(value), do: is_nil(present(value))

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
