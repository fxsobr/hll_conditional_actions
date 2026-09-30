defmodule HllConditionalActions.VipShop.Emails do
  @moduledoc """
  The shop's emails: which ones exist, what they say by default, and how an
  admin's edited version is turned into a message.

  A template is a subject and a body with `{placeholders}`. Only the
  placeholders given are filled; anything else is left as typed, so a typo
  shows up in the test email instead of vanishing.

  The body is plain text with a few marks, and goes out as HTML (with the
  storefront's logo and accent colour) and as plain text:

    * `**bold**` and `[text](https://link)`
    * `[order summary]` (or `[resumo do pedido]`) on its own line: the
      package, how it was paid and the player
    * `[button: Label → {shop_url}]` (or `[botão: …]`) on its own line

  Two emails are optional: "expiring" (on unless switched off) and
  "delivery_failed" (off until switched on), each kept as `"enabled"` in
  its stored template.
  """

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Swoosh.Email

  alias HllConditionalActions.VipShop.{Design, Settings}

  @templates %{
    "welcome" => %{
      placeholders: ~w(name shop),
      subject: "Welcome to {shop}",
      body: """
      Hi {name},

      Your account at {shop} is ready. Link your in-game player and pick a VIP package whenever you like.

      See you on the battlefield!
      """
    },
    "reset" => %{
      placeholders: ~w(name shop link),
      subject: "Reset your password at {shop}",
      body: """
      Hi {name},

      Somebody asked to reset the password of your account at {shop}. If it was you, choose a new one here within the next 30 minutes:

      {link}

      If it was not you, ignore this email: your password stays the same.
      """
    },
    "expiring" => %{
      placeholders: ~w(name shop package player servers date link),
      subject: "Your VIP ends on {date}",
      body: """
      Hi {name},

      {package} for {player} ends on {date} on: {servers}.

      Renew it before then to keep your perks - with the shop set to add time, the new days start when the current ones end:

      {link}

      {shop}
      """
    },
    "purchase" => %{
      placeholders: ~w(name shop order_id package player amount servers expires_at shop_url),
      subject: "Your VIP is active - order {order_id}",
      body: """
      Hi {name},

      Thanks for your purchase! {package} is now active for {player} on: {servers}.

      [order summary]

      [button: Follow the delivery → {shop_url}]

      {shop}
      """
    },
    "delivery_failed" => %{
      placeholders: ~w(name shop order_id package player servers shop_url),
      subject: "Your VIP is taking longer on a server - order {order_id}",
      body: """
      Hi {name},

      Your payment for {package} went through, but a server did not confirm the VIP for {player} yet. We keep trying on our own and the team was warned.

      [button: Follow the delivery → {shop_url}]

      {shop}
      """
    }
  }

  @doc "Every email the shop sends, in display order."
  @spec names() :: [String.t()]
  def names, do: ~w(welcome reset purchase expiring delivery_failed)

  @doc "The emails that only go out when switched on."
  @spec optional() :: [String.t()]
  def optional, do: ~w(expiring delivery_failed)

  @doc "The placeholders a template can use."
  @spec placeholders(String.t()) :: [String.t()]
  def placeholders(name), do: @templates |> Map.fetch!(name) |> Map.fetch!(:placeholders)

  @doc """
  A template's subject and body: the admin's version where there is one,
  the default otherwise.
  """
  @spec template(Settings.t(), String.t()) :: %{subject: String.t(), body: String.t()}
  def template(%Settings{email_templates: stored}, name) do
    default = Map.fetch!(@templates, name)
    custom = Map.get(stored || %{}, name, %{})

    %{
      subject: present(custom["subject"]) || default.subject,
      body: present(custom["body"]) || default.body
    }
  end

  @doc "The default subject and body of a template."
  @spec default(String.t()) :: %{subject: String.t(), body: String.t()}
  def default(name), do: @templates |> Map.fetch!(name) |> Map.take([:subject, :body])

  @doc "Whether the admin rewrote a template."
  @spec custom?(Settings.t(), String.t()) :: boolean()
  def custom?(%Settings{email_templates: stored}, name) do
    custom = Map.get(stored || %{}, name, %{})
    present(custom["subject"]) != nil or present(custom["body"]) != nil
  end

  @doc """
  Whether an email goes out: the optional ones follow their switch
  ("expiring" is on until switched off, "delivery_failed" off until on).
  """
  @spec enabled?(Settings.t(), String.t()) :: boolean()
  def enabled?(%Settings{email_templates: stored}, name) do
    flag = get_in(stored || %{}, [name, "enabled"])

    case name do
      "expiring" -> flag != false
      "delivery_failed" -> flag == true
      _always -> true
    end
  end

  @doc """
  Fills a template's placeholders.

      iex> HllConditionalActions.VipShop.Emails.render("Hi {name}, {nope}", %{"name" => "Ana"})
      "Hi Ana, {nope}"
  """
  @spec render(String.t(), map()) :: String.t()
  def render(text, vars) do
    Regex.replace(~r/\{([a-z_]+)\}/, text, fn whole, key ->
      case Map.fetch(vars, key) do
        {:ok, value} -> to_string(value)
        :error -> whole
      end
    end)
  end

  @doc """
  The body as blocks, for the HTML and the preview:
  `{:paragraph, [line]}` where a line is a list of segments
  (`{:text, s}`, `{:var, key, value}`, `{:bold, segments}`,
  `{:link, segments, url}`), `{:summary}` and `{:button, label, url}`.

      iex> alias HllConditionalActions.VipShop.Emails
      iex> Emails.blocks("Hi **{name}**\\n[button: Go → {url}]", %{"name" => "Ana", "url" => "https://x"})
      [{:paragraph, [[{:text, "Hi "}, {:bold, [{:var, "name", "Ana"}]}]]}, {:button, "Go", "https://x"}]
  """
  @spec blocks(String.t(), map()) :: [tuple()]
  def blocks(body, vars) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.chunk_while(
      [],
      fn line, acc ->
        cond do
          String.trim(line) == "" -> {:cont, Enum.reverse(acc), []}
          special = special_line(line, vars) -> {:cont, Enum.reverse(acc), [{:special, special}]}
          true -> {:cont, [line | acc]}
        end
      end,
      &{:cont, Enum.reverse(&1), []}
    )
    |> Enum.flat_map(fn
      [] ->
        []

      [{:special, special}] ->
        [special]

      [{:special, special} | lines] ->
        [special, {:paragraph, Enum.map(lines, &segments(&1, vars))}]

      lines ->
        [{:paragraph, Enum.map(lines, &segments(&1, vars))}]
    end)
  end

  defp special_line(line, vars) do
    line = String.trim(line)

    cond do
      line =~ ~r/^\[(order summary|resumo do pedido)\]$/iu ->
        {:summary}

      match = Regex.run(~r/^\[(?:button|botão|botao):\s*(.+?)\s*(?:→|->)\s*(.+?)\s*\]$/iu, line) ->
        [_all, label, url] = match
        {:button, render(label, vars), render(url, vars)}

      true ->
        nil
    end
  end

  # **bold**, [text](url) and {placeholders}, in that order of precedence.
  defp segments(line, vars) do
    ~r/\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)/u
    |> Regex.split(line, include_captures: true)
    |> Enum.flat_map(fn part ->
      cond do
        match = Regex.run(~r/^\*\*(.+)\*\*$/u, part) ->
          [{:bold, vars_in(Enum.at(match, 1), vars)}]

        match = Regex.run(~r/^\[([^\]]+)\]\(([^)\s]+)\)$/u, part) ->
          [{:link, vars_in(Enum.at(match, 1), vars), render(Enum.at(match, 2), vars)}]

        true ->
          vars_in(part, vars)
      end
    end)
  end

  defp vars_in(text, vars) do
    ~r/\{([a-z_]+)\}/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      with [_whole, key] <- Regex.run(~r/^\{([a-z_]+)\}$/, part),
           {:ok, value} <- Map.fetch(vars, key) do
        {:var, key, to_string(value)}
      else
        _text -> {:text, part}
      end
    end)
  end

  @doc "The rows of the order summary block, from the receipt's placeholders."
  @spec summary_rows(map()) :: [{String.t(), String.t()}]
  def summary_rows(vars) do
    [
      {gettext("Package"), join([vars["package"], vars["duration"]])},
      {gettext("Paid with"), join([vars["provider"], vars["amount"]])},
      {gettext("Player"), join([vars["player"], vars["player_id"]])}
    ]
    |> Enum.reject(fn {_label, value} -> value == "" end)
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  @doc "Builds the message for a template, ready to deliver."
  @spec build(Settings.t(), String.t(), String.t(), map()) :: Swoosh.Email.t()
  def build(%Settings{} = settings, name, to, vars) do
    %{subject: subject, body: body} = template(settings, name)
    build_text(settings, subject, body, to, vars)
  end

  @doc "Builds a message from a subject and body given as text, such as an unsaved draft."
  @spec build_text(Settings.t(), String.t(), String.t(), String.t(), map()) :: Swoosh.Email.t()
  def build_text(%Settings{} = settings, subject, body, to, vars) do
    blocks = blocks(body, vars)

    new()
    |> from(
      {settings.mail_from_name || settings.shop_title || "VIP Shop", settings.mail_from_address}
    )
    |> to(to)
    |> subject(render(subject, vars))
    |> text_body(text(blocks, vars))
    |> html_body(html(settings, blocks, vars))
  end

  @doc "The plain text version of a body's blocks."
  @spec text([tuple()], map()) :: String.t()
  def text(blocks, vars) do
    Enum.map_join(blocks, "\n\n", fn
      {:paragraph, lines} -> Enum.map_join(lines, "\n", &plain/1)
      {:summary} -> Enum.map_join(summary_rows(vars), "\n", fn {k, v} -> "#{k}: #{v}" end)
      {:button, label, url} -> "#{label}: #{url}"
    end)
  end

  defp plain(segments) when is_list(segments), do: Enum.map_join(segments, &plain/1)
  defp plain({:text, text}), do: text
  defp plain({:var, _key, value}), do: value
  defp plain({:bold, segments}), do: plain(segments)
  defp plain({:link, segments, url}), do: "#{plain(segments)} (#{url})"

  @doc """
  The HTML version: a card under a dark bar with the storefront's logo,
  name and accent colour.
  """
  @spec html(Settings.t(), [tuple()], map()) :: String.t()
  def html(%Settings{} = settings, blocks, vars) do
    design = Design.get(settings.design)
    accent = design["accent"] || Design.theme(design["theme"]).accent
    on_accent = Design.on_color(accent)
    shop = escape(settings.shop_title || vars["shop"] || "VIP Shop")
    base = HllConditionalActionsWeb.Endpoint.url()

    logo =
      if settings.logo_asset_id,
        do:
          ~s(<img src="#{base}/shop/assets/#{settings.logo_asset_id}" alt="" width="30" height="30" style="border-radius:9px;vertical-align:middle;margin-right:10px">),
        else: ""

    content =
      Enum.map_join(blocks, "\n", fn
        {:paragraph, lines} ->
          ~s(<p style="margin:0 0 12px;font-size:14px;line-height:1.55;color:#4f5148">) <>
            Enum.map_join(lines, "<br>", &html_segments(&1, accent)) <> "</p>"

        {:summary} ->
          rows =
            Enum.map_join(summary_rows(vars), "", fn {label, value} ->
              ~s(<tr><td style="padding:6px 0;color:#6b6d64;font-size:12px">#{escape(label)}</td>) <>
                ~s(<td style="padding:6px 0;text-align:right;font-size:12px;color:#16170f">#{escape(value)}</td></tr>)
            end)

          ~s(<table role="presentation" width="100%" style="margin:0 0 14px;border-radius:12px;background:#f2f1eb;padding:4px 14px">#{rows}</table>)

        {:button, label, url} ->
          ~s(<p style="margin:4px 0 12px"><a href="#{escape(url)}" style="display:inline-block;padding:10px 18px;border-radius:999px;background:#{accent};color:#{on_accent};font-size:13px;font-weight:600;text-decoration:none">#{escape(label)}</a></p>)
      end)

    """
    <!doctype html>
    <html><body style="margin:0;padding:20px 0;background:#e9e8e1;font-family:Helvetica,Arial,sans-serif">
    <table role="presentation" width="100%"><tr><td align="center">
    <table role="presentation" width="470" style="max-width:470px;background:#ffffff;border-radius:14px;overflow:hidden">
    <tr><td style="background:#14160f;padding:12px 18px;color:#f3f2ec;font-size:15px;font-weight:700">#{logo}#{shop}
    <span style="float:right;display:inline-block;margin-top:8px;width:44px;height:4px;border-radius:2px;background:#{accent}"></span></td></tr>
    <tr><td style="padding:16px 22px 10px;color:#16170f">#{content}</td></tr>
    </table></td></tr></table>
    </body></html>
    """
  end

  defp html_segments(segments, accent) when is_list(segments),
    do: Enum.map_join(segments, &html_segment(&1, accent))

  defp html_segment({:text, text}, _accent), do: escape(text)
  defp html_segment({:var, _key, value}, _accent), do: escape(value)

  defp html_segment({:bold, segments}, accent),
    do: "<strong>" <> html_segments(segments, accent) <> "</strong>"

  defp html_segment({:link, segments, url}, _accent),
    do:
      ~s(<a href="#{escape(url)}" style="color:#3f5c00">) <>
        html_segments(segments, nil) <> "</a>"

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  The Swoosh options for the configured email service.

      iex> alias HllConditionalActions.VipShop.{Emails, Settings}
      iex> Emails.delivery_config(%Settings{email_provider: "brevo", email_api_key: "k"})
      [adapter: Swoosh.Adapters.Brevo, api_key: "k"]
  """
  @spec delivery_config(Settings.t()) :: keyword()
  def delivery_config(%Settings{email_provider: "sendgrid", email_api_key: key}),
    do: [adapter: Swoosh.Adapters.Sendgrid, api_key: key]

  def delivery_config(%Settings{email_provider: "brevo", email_api_key: key}),
    do: [adapter: Swoosh.Adapters.Brevo, api_key: key]

  def delivery_config(%Settings{} = s) do
    [
      adapter: Swoosh.Adapters.SMTP,
      relay: s.smtp_host,
      port: s.smtp_port || default_port(s.smtp_tls),
      username: s.smtp_username,
      password: s.smtp_password,
      auth: if(present(s.smtp_username), do: :always, else: :never),
      ssl: s.smtp_tls == "ssl",
      tls: if(s.smtp_tls == "starttls", do: :always, else: :never),
      tls_options: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 5],
      retries: 1
    ]
  end

  defp default_port("ssl"), do: 465
  defp default_port("starttls"), do: 587
  defp default_port(_none), do: 25

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil
end
