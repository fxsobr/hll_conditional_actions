import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hll_conditional_actions, HllConditionalActions.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: "hll_conditional_actions_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Jobs run inline so a test can assert on their effect without waiting for a
# queue, and the cron plugin is off so nothing fires on its own.
config :hll_conditional_actions, Oban, testing: :manual

# No test may reach a real CRCON deployment: `Req.Test` intercepts every
# request and answers with whatever the test stubbed. Retries are off so a test
# that stubs a failure gets it immediately.
config :hll_conditional_actions, :crcon_req_options,
  plug: {Req.Test, HllConditionalActions.Crcon},
  retry: false

# Seeding at boot would run outside the Ecto sandbox; tests that need roles or
# the bootstrap admin call `Accounts.bootstrap!/0` themselves.
config :hll_conditional_actions, :bootstrap_on_boot, false

# The engine connects to CRCON over WebSocket and evaluates rules on a timer;
# tests drive it directly instead.
config :hll_conditional_actions, :engine_enabled, false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "P7b8Tfht9NfTwL7UbJVjcGyMTq8+j0Y7jL0btBJQbPRcezpqr2ckNe5Ej7RsYK5p",
  server: false

# One round rather than the default hundreds of thousands. Every fixture hashes
# a password, and enrolling in two factor hashes ten recovery codes on top of
# it; at production cost the suite spends most of its time deliberately being
# slow. What is being tested is the flow, not the KDF.
config :pbkdf2_elixir, rounds: 1

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The whole suite signs in from 127.0.0.1, far more often than a person would.
# The limiter itself is covered by its own test, which sets these low.
config :hll_conditional_actions, :login_rate_limit,
  ip: [limit: 1_000_000, window_ms: 60_000],
  username: [limit: 1_000_000, window_ms: 3_600_000]
