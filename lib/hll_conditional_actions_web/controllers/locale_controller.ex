defmodule HllConditionalActionsWeb.LocaleController do
  @moduledoc """
  Stores the visitor's language choice in the session.
  """

  use HllConditionalActionsWeb, :controller

  alias HllConditionalActionsWeb.Plugs.Locale

  def update(conn, %{"locale" => locale} = params) do
    conn =
      if Locale.supported?(locale) do
        put_session(conn, Locale.session_key(), locale)
      else
        conn
      end

    # Only ever redirect within this app: a "return to" taken from a query
    # string is attacker controlled.
    redirect(conn, to: safe_path(params["return_to"]))
  end

  defp safe_path("/" <> _rest = path), do: path
  defp safe_path(_other), do: "/"
end
