defmodule HllConditionalActions.MixProject do
  use Mix.Project

  def project do
    [
      app: :hll_conditional_actions,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  def application do
    [
      mod: {HllConditionalActions.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:petal_components, "~> 4.13"},
      {:req, "~> 0.5"},
      # QR codes for the two factor enrolment screen. Pure Elixir, no NIF.
      {:eqrcode, "~> 0.2"},
      {:oban, "~> 2.19"},
      # IANA time zones, so "only after 22:00" means the players' local time
      # and follows daylight saving. `tz` over `tzdata` because the latter
      # pulls in hackney just to auto-update its data files.
      {:tz, "~> 0.28"},
      # Pure Elixir password hashing: no C toolchain needed, so the same build
      # works on every platform the project is developed on.
      {:pbkdf2_elixir, "~> 2.2"},
      {:mint_web_socket, "~> 1.0"},
      # Trust store for the WebSocket client's TLS connections.
      {:castore, "~> 1.0"},
      {:cloak_ecto, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Static analysis. Dev and test only, and never at runtime.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Shortcuts. `mix setup` prepares a checkout; `mix precommit` is what has to
  # pass before anything is committed.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind hll_conditional_actions",
        "esbuild hll_conditional_actions"
      ],
      "assets.deploy": [
        "tailwind hll_conditional_actions --minify",
        "esbuild hll_conditional_actions --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
