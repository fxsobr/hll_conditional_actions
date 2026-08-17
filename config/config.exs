# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hll_conditional_actions,
  ecto_repos: [HllConditionalActions.Repo],
  generators: [timestamp_type: :utc_datetime]

# Petal Components pushes form errors through the same gettext-backed
# translator the rest of the app uses.
config :petal_components,
       :error_translator_function,
       {HllConditionalActionsWeb.CoreComponents, :translate_error}

# How long the engine keeps rule execution history, and how often it prunes.
config :hll_conditional_actions, :execution_retention_days, 30

# Background jobs, backed by the same Postgres database.
#
#   * `actions` - deliveries that may safely be retried (Discord webhooks) and
#     delayed follow-ups such as restoring a temporary broadcast
#   * `maintenance` - housekeeping driven by the cron plugin
#
# In-game punishments are NOT queued: a kick that lands 30 seconds late would
# punish a situation that has already passed, so those run inline.
config :hll_conditional_actions, Oban,
  repo: HllConditionalActions.Repo,
  queues: [actions: 10, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", HllConditionalActions.Workers.PruneExecutions}
     ]}
  ]

# Internationalization. The source language is English; pt_BR ships translated.
#
# Gettext reads this at compile time, so it cannot be changed by an environment
# variable. The locale actually served per request comes from
# `:default_locale` below, which `HllConditionalActionsWeb.Plugs.Locale` reads
# at runtime.
config :hll_conditional_actions, HllConditionalActionsWeb.Gettext,
  default_locale: "en",
  locales: ~w(en pt_BR)

config :hll_conditional_actions, :default_locale, "en"

# IANA time zones, so a server's "after 22:00" rule follows its community's
# local time including daylight saving.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Encryption of CRCON API keys at rest. The dev and test keys are overridden
# from ENCRYPTION_KEY in config/runtime.exs for every other environment.
config :hll_conditional_actions, HllConditionalActions.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("gAOEDwRRAQwCXLXJZ1MOJmuTvGjq2wKKtEWmWnhKZWo=")}
  ]

# Configure the endpoint
config :hll_conditional_actions, HllConditionalActionsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HllConditionalActionsWeb.ErrorHTML, json: HllConditionalActionsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HllConditionalActions.PubSub,
  live_view: [signing_salt: "aSbD1W/1"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r",
  # We keep colocated hooks self-contained, so the symlink into
  # assets/node_modules is not needed (and needs elevation on Windows).
  colocated_assets: [disable_symlink_warning: true]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  hll_conditional_actions: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  hll_conditional_actions: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Where the About dialog reads its release notes from. Public data on a
# public repository, so the check is unauthenticated.
config :hll_conditional_actions, :updates, repository: "fxsobr/hll_conditional_actions"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
