defmodule HllConditionalActionsWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds the response headers Phoenix's own `put_secure_browser_headers/2` does
  not: a content security policy and a permissions policy.

  Set here rather than in Caddy so that they hold however the app is served —
  a deployment behind somebody else's proxy, or a bare `bin/server` on a
  laptop, still gets them.

  ## About `script-src`

  The policy allows `'unsafe-inline'` and `'unsafe-eval'` for scripts, which
  is the weakest part of it and worth being plain about. Two things need them:

    * Alpine.js reads expressions out of `x-*` attributes and evaluates them,
      which is `eval` by another name. Alpine ships a CSP build that does not,
      at the cost of the inline expression syntax this app's components use
      throughout.
    * Petal's colour scheme script is inline, and has to be: it applies the
      saved theme before first paint, and an external script would show a flash
      of the wrong one. It takes no nonce.

  What keeps XSS out meanwhile is that HEEx escapes everything by construction.
  There is exactly one `raw/1` in `lib/hll_conditional_actions_web` — the QR
  code on the two factor enrolment screen, an SVG this app generates from a
  secret it generated itself, with nothing from a user anywhere in it. The rest
  of the policy is still worth having: it stops the page being framed, stops
  form posts to other origins, and stops any plugin, object or base tag
  redirection.
  """

  import Plug.Conn

  @behaviour Plug

  # Phoenix's live reloader watches for changes through a same-origin iframe,
  # which `frame-src 'none'` blocks. It only exists where dev routes do.
  @frame_src if Application.compile_env(:hll_conditional_actions, :dev_routes, false),
               do: "frame-src 'self'",
               else: "frame-src 'none'"

  @csp [
         # Anything not named below may only come from this origin.
         "default-src 'self'",
         # See the note in the moduledoc.
         "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
         # LiveView writes inline styles to run its transitions.
         "style-src 'self' 'unsafe-inline'",
         # `data:` covers the inlined icons in the stylesheet.
         "img-src 'self' data:",
         "font-src 'self'",
         # The LiveView socket. `'self'` covers ws/wss on the same origin.
         "connect-src 'self'",
         # This app has no reason to be inside anybody's frame.
         "frame-ancestors 'none'",
         @frame_src,
         "base-uri 'self'",
         "form-action 'self'",
         "object-src 'none'"
       ]
       |> Enum.join("; ")

  # Nothing here uses a camera, a microphone or a location, so nothing here
  # should be able to ask for one.
  @permissions_policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("permissions-policy", @permissions_policy)
  end
end
