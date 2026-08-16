defmodule HllConditionalActionsWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Refuses sign in attempts once there have been too many.

  Two counters, because they answer different attacks:

    * by address — one machine hammering the form
    * by username — a botnet spreading its guesses across many addresses, each
      of which stays under the address limit

  Either being over the line is enough to refuse. The username counter is the
  one that matters most: it is the only one an attacker cannot escape by
  renting more addresses.

  Failing is a plain 401 with the same wording as a wrong password, plus a
  `Retry-After`. Saying "too many attempts for this account" would confirm the
  account exists, which is exactly what the login page works to avoid telling
  anybody.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [render: 3, put_view: 2]

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  alias HllConditionalActions.RateLimit

  # Generous enough that a person who forgot which password they used is not
  # locked out, small enough that guessing is hopeless: 10 a minute for a
  # single address, and 20 an hour against one account. Overridable so the
  # test suite can sign in as often as it likes, and so a deployment behind a
  # single office NAT can raise the address limit.
  @defaults [
    ip: [limit: 10, window_ms: 60_000],
    username: [limit: 20, window_ms: 3_600_000]
  ]

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    username = conn.params |> get_in(["user", "username"]) |> normalize()

    # Both counters are spent even when the first already refuses, so an
    # attacker cannot keep one of them fresh by tripping the other.
    checks = [
      RateLimit.check("login:ip:#{client_ip(conn)}", limits(:ip)),
      RateLimit.check("login:user:#{username}", limits(:username))
    ]

    case Enum.find(checks, &match?({:error, :rate_limited, _seconds}, &1)) do
      nil -> conn
      {:error, :rate_limited, seconds} -> refuse(conn, seconds, username)
    end
  end

  def call(conn, _opts), do: conn

  # `|| []` rather than a default argument: a deployment that sets the key to
  # nil to "turn it off" would otherwise crash the limiter into failing open,
  # which is the opposite of what it was asked to do.
  defp limits(which) do
    configured = Application.get_env(:hll_conditional_actions, :login_rate_limit) || []

    Keyword.get(configured, which, @defaults[which])
  end

  @doc """
  Clears both counters after a successful sign in.

  Called by the session controller rather than by this plug, because the plug
  runs before anyone knows whether the password was right.
  """
  @spec succeeded(Plug.Conn.t(), String.t()) :: :ok
  def succeeded(conn, username) do
    RateLimit.reset("login:ip:#{client_ip(conn)}")
    RateLimit.reset("login:user:#{normalize(username)}")
  end

  # ── The client's address ───────────────────────────────────────────────────

  # The address to count against.
  #
  # Behind Caddy every request arrives from the proxy, so `remote_ip` is the
  # proxy for all of them and an address limit would lock out the whole world at
  # once. `X-Forwarded-For` carries the real one — but it is a header, and a
  # header is whatever the client says it is, so it is only trusted when the
  # deployment has declared that something in front is rewriting it
  # (`:trust_proxy_headers`, set for the compose stack that ships Caddy).
  #
  # Only the first entry is read. Caddy replaces the header with the address it
  # is talking to rather than appending to what the client sent, so there is
  # normally just the one — but reading the first entry is also what keeps this
  # right in front of a proxy that appends, where anything after the first was
  # added by a hop closer to us.
  defp client_ip(conn) do
    if trust_proxy_headers?() do
      case get_req_header(conn, "x-forwarded-for") do
        [value | _rest] -> value |> String.split(",") |> List.first() |> String.trim()
        [] -> peer_ip(conn)
      end
    else
      peer_ip(conn)
    end
  end

  defp peer_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp trust_proxy_headers? do
    Application.get_env(:hll_conditional_actions, :trust_proxy_headers, false)
  end

  # ── Refusing ───────────────────────────────────────────────────────────────

  defp refuse(conn, seconds, username) do
    conn
    |> put_resp_header("retry-after", to_string(seconds))
    |> put_status(:too_many_requests)
    |> put_view(html: HllConditionalActionsWeb.SessionHTML)
    |> render(:new,
      error:
        gettext("Too many sign in attempts. Try again in %{seconds} seconds.", seconds: seconds),
      username: username,
      first_run?: false
    )
    |> halt()
  end

  defp normalize(nil), do: ""
  defp normalize(username), do: username |> to_string() |> String.trim() |> String.downcase()
end
