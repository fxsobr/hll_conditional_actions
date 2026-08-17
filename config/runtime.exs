import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hll_conditional_actions start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint, server: true
end

config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Environment driven settings. Skipped in :test, where `config/test.exs` is the
# authority and an env var left over from a dev shell must not leak in.
if config_env() != :test do
  # Locale served when a request does not ask for anything else. This is an
  # app env key rather than Gettext's own `:default_locale`, which Gettext
  # reads at compile time and a release refuses to see changed at boot.
  if locale = System.get_env("DEFAULT_LOCALE") do
    config :hll_conditional_actions, :default_locale, locale
  end

  # Whether the engine connects to CRCON and evaluates rules in this node. Set
  # it to "false" for a node that only serves the UI, or while debugging.
  config :hll_conditional_actions,
         :engine_enabled,
         System.get_env("ENGINE_ENABLED", "true") not in ~w(false 0 no)

  config :hll_conditional_actions,
         :execution_retention_days,
         String.to_integer(System.get_env("EXECUTION_RETENTION_DAYS", "30"))

  # How long to wait after a CONNECTED log line before evaluating rules, so the
  # player exists in CRCON's view by then. Raise it for a slow game server.
  config :hll_conditional_actions,
         :connect_delay_ms,
         String.to_integer(System.get_env("CONNECT_DELAY_MS", "5000"))
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/hll_conditional_actions_web/router\.ex$"E,
        ~r"lib/hll_conditional_actions_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # CRCON API keys are stored encrypted. Losing this key means every stored key
  # has to be entered again, so keep it with your other secrets.
  encryption_key =
    System.get_env("ENCRYPTION_KEY") ||
      raise """
      environment variable ENCRYPTION_KEY is missing.
      Generate a 32 byte base64 key with:

          openssl rand -base64 32
      """

  config :hll_conditional_actions, HllConditionalActions.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(encryption_key)}
    ]

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :hll_conditional_actions, HllConditionalActions.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Two separate questions, because with Caddy on a plain HTTP port the
  # answers differ:
  #
  #   BEHIND_PROXY  is something in front setting X-Forwarded-For? Believing
  #                 that header with nothing in front lets any client name its
  #                 own address and walk past the sign in limiter.
  #
  #   FORCE_HTTPS   is the *public* connection TLS? It decides whether plain
  #                 HTTP is redirected, whether HSTS is sent, and whether the
  #                 session cookie is `secure`. A secure cookie is never sent
  #                 over plain HTTP, so saying yes when it is not produces an
  #                 app where signing in appears to work and then does not.
  behind_proxy? = System.get_env("BEHIND_PROXY", "true") not in ~w(false 0 no)
  force_https? = System.get_env("FORCE_HTTPS", "false") not in ~w(false 0 no)

  config :hll_conditional_actions,
    secure_cookies: force_https?,
    force_https: force_https?,
    trust_proxy_headers: behind_proxy?

  config :hll_conditional_actions, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  {scheme, url_port} =
    if force_https?,
      do: {"https", 443},
      else: {"http", String.to_integer(System.get_env("PUBLIC_PORT", "4000"))}

  config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # TLS is terminated by Caddy in `compose.prod.yaml`, so the release itself
  # only ever speaks plain HTTP on the compose network. `force_ssl` in
  # config/prod.exs reads `X-Forwarded-Proto` to redirect anything that
  # somehow arrived unencrypted, and to set HSTS.
  #
  # To serve TLS from the release instead — no proxy at all — add an `https`
  # key here with `cipher_suite: :strong`, `keyfile` and `certfile`, and take
  # on renewing the certificate yourself. See Plug.SSL for the options.
end
