# LiveView's render_async and assert_receive share this timeout; 100 ms is too
# tight for pages that load in the background while the whole suite runs.
ExUnit.start(assert_receive_timeout: 1_000)

# The built-in roles are shared by every test. Creating them once, committed,
# keeps async tests from racing to insert the same rows inside their sandboxes
# (which deadlocks under load).
HllConditionalActions.Accounts.ensure_system_roles!()

Ecto.Adapters.SQL.Sandbox.mode(HllConditionalActions.Repo, :manual)
