defmodule HllConditionalActionsWeb.Plugs.Locale do
  @moduledoc """
  Picks the locale for a request.

  Order of preference: an explicit choice stored in the session, then the
  browser's `accept-language` header, then the configured default. The chosen
  locale is put back into the session so LiveView mounts can restore it - a
  LiveView runs in its own process and does not inherit the request's Gettext
  locale.
  """

  import Plug.Conn

  @behaviour Plug

  @session_key "locale"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    locale = get_session(conn, @session_key) || from_header(conn) || default_locale()

    Gettext.put_locale(HllConditionalActionsWeb.Gettext, locale)
    put_session(conn, @session_key, locale)
  end

  @doc """
  Restores the locale inside a LiveView process.

  Used as an `on_mount` hook, since `call/2` only affects the HTTP request.
  """
  def on_mount(:default, _params, session, socket) do
    Gettext.put_locale(
      HllConditionalActionsWeb.Gettext,
      session[@session_key] || default_locale()
    )

    {:cont, socket}
  end

  @doc """
  The locales this application ships translations for.
  """
  @spec supported() :: [String.t()]
  def supported, do: Gettext.known_locales(HllConditionalActionsWeb.Gettext)

  @doc """
  Whether a value is a locale we can serve.
  """
  @spec supported?(String.t() | nil) :: boolean()
  def supported?(locale), do: locale in supported()

  @doc """
  The session key holding the chosen locale.
  """
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  The configured fallback locale.

  Comes from `DEFAULT_LOCALE`. An unsupported value falls back to Gettext's own
  compile-time default rather than serving missing translations.
  """
  @spec default_locale() :: String.t()
  def default_locale do
    configured = Application.get_env(:hll_conditional_actions, :default_locale)

    if supported?(configured) do
      configured
    else
      Gettext.get_locale(HllConditionalActionsWeb.Gettext)
    end
  end

  # "pt-BR,pt;q=0.9,en;q=0.8" -> the first entry we have translations for.
  # Gettext names locales with an underscore, browsers with a hyphen.
  defp from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> to_string()
    |> String.split(",")
    |> Enum.map(fn tag ->
      tag |> String.split(";") |> List.first() |> to_string() |> String.trim()
    end)
    |> Enum.flat_map(&candidates/1)
    |> Enum.find(&supported?/1)
  end

  defp candidates(""), do: []

  defp candidates(tag) do
    normalized = String.replace(tag, "-", "_")
    [normalized, normalized |> String.split("_") |> List.first()]
  end
end
