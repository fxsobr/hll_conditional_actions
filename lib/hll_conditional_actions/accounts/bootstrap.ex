defmodule HllConditionalActions.Accounts.Bootstrap do
  @moduledoc """
  Makes sure there is always a way into a fresh install.

  Runs once at boot, right after the repo starts: it creates the built-in roles
  and, when the database has no users at all, the initial `admin` / `admin`
  account flagged to change its password on first sign in.

  A missing `users` table simply means migrations have not run yet (a release
  runs them from its entrypoint), so that case is logged and skipped rather
  than crashing the whole application.
  """

  use Task, restart: :transient

  require Logger

  alias HllConditionalActions.Accounts

  @doc false
  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  @doc """
  Seeds roles and the bootstrap administrator.

  Does nothing when `:bootstrap_on_boot` is disabled, which is how the test
  environment keeps this out of the Ecto sandbox: tests that need the seed data
  call `HllConditionalActions.Accounts.bootstrap!/0` themselves.
  """
  @spec run() :: :ok
  def run do
    if Application.get_env(:hll_conditional_actions, :bootstrap_on_boot, true) do
      Accounts.bootstrap!()
      log_bootstrap_hint()
    end

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("""
      [accounts] skipping bootstrap: #{Exception.message(error)}
      Run migrations first (mix ecto.migrate, or bin/hll_conditional_actions eval "HllConditionalActions.Release.migrate").
      """)

      :ok

    # Never take the application down over seeding. Restarting into the same
    # failure would only produce a crash loop and hide the real error.
    error ->
      Logger.error("[accounts] bootstrap failed: #{Exception.message(error)}")
      :ok
  end

  defp log_bootstrap_hint do
    %{username: username, password: password} = Accounts.bootstrap_credentials()

    if Accounts.get_user_by_username(username) |> needs_password_change?() do
      Logger.warning("""
      [accounts] the bootstrap administrator is still using its default password.
      Sign in with #{username} / #{password} and set a new one.
      """)
    end
  end

  defp needs_password_change?(nil), do: false
  defp needs_password_change?(user), do: user.must_change_password?
end
