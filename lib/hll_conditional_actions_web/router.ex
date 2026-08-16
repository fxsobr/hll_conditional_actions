defmodule HllConditionalActionsWeb.Router do
  use HllConditionalActionsWeb, :router

  import HllConditionalActionsWeb.UserAuth

  alias HllConditionalActionsWeb.Plugs
  alias HllConditionalActionsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HllConditionalActionsWeb.Layouts, :root}
    # Runs first so a sign in form that outlived its session is answered with a
    # fresh form instead of a CSRF error page. Everything else, including the
    # sign in form with a valid token, goes through :protect_from_forgery.
    plug Plugs.StaleLoginForm
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Plugs.SecurityHeaders
    plug Plugs.Locale
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Password guessing is the only attack this app exposes to the open internet,
  # so the sign in form gets a counter of its own. Caddy limits by address in
  # front; this one also limits by account.
  pipeline :throttle_login do
    plug Plugs.LoginRateLimit
  end

  # Probes are unauthenticated on purpose: they run before anyone can sign in.
  scope "/health", HllConditionalActionsWeb do
    pipe_through :api

    get "/", HealthController, :index
    get "/ready", HealthController, :ready
  end

  # Everyone, signed in or not.
  scope "/", HllConditionalActionsWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update
    delete "/logout", SessionController, :delete
  end

  scope "/", HllConditionalActionsWeb do
    # The rate limiter runs after :redirect_if_authenticated, so somebody who
    # is already signed in never spends a counter by reloading /login.
    pipe_through [:browser, :redirect_if_authenticated, :throttle_login]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  # The second factor. Not behind :require_authenticated_user, because the
  # visitor deliberately is not authenticated yet — the controller's own plug
  # is what demands a session that has passed the password.
  scope "/", HllConditionalActionsWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/login/code", TwoFactorController, :new
    post "/login/code", TwoFactorController, :create
  end

  # The password form is reachable while `must_change_password?` is set, which
  # is exactly when every other authenticated page redirects away.
  scope "/", HllConditionalActionsWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/rules/export", RuleExportController, :export
  end

  scope "/", HllConditionalActionsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :password_change,
      on_mount: [
        {Plugs.Locale, :default},
        {UserAuth, :ensure_authenticated_allow_password_change}
      ] do
      live "/account/password", AccountLive.Password, :edit
    end
  end

  scope "/", HllConditionalActionsWeb do
    pipe_through [:browser, :require_authenticated_user]

    # One live_session for every authenticated page, because navigating across
    # live_sessions forces a full page reload - which would happen on every
    # click in the sidebar. Per-page permissions are declared by the LiveViews
    # themselves with `on_mount {UserAuth, {:ensure_permission, ...}}`, so they
    # are still enforced server side.
    live_session :authenticated,
      on_mount: [{Plugs.Locale, :default}, {UserAuth, :ensure_authenticated}] do
      live "/", DashboardLive, :index
      live "/account", AccountLive.Show, :show

      live "/servers", ServerLive.Index, :index
      live "/servers/new", ServerLive.Index, :new
      live "/servers/:id/edit", ServerLive.Index, :edit
      live "/servers/:id", ServerLive.Show, :show

      live "/rules", RuleLive.Index, :index
      live "/rules/new", RuleLive.Form, :new
      live "/rules/:id", RuleLive.Show, :show
      live "/rules/:id/edit", RuleLive.Form, :edit

      live "/feed", FeedLive, :index
      live "/executions", ExecutionLive.Index, :index
      live "/players/:player_id", PlayerLive.Show, :show
      live "/metrics", MetricsLive, :index

      live "/users", UserLive.Index, :index
      live "/users/new", UserLive.Index, :new
      live "/users/:id/edit", UserLive.Index, :edit

      live "/roles", RoleLive.Index, :index
      live "/roles/new", RoleLive.Index, :new
      live "/roles/:id/edit", RoleLive.Index, :edit
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:hll_conditional_actions, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HllConditionalActionsWeb.Telemetry
    end
  end
end
