# Seeds the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Safe to run repeatedly: it only creates what is missing.
#
# The built-in roles and the bootstrap `admin` / `admin` account are also
# created automatically at boot by `HllConditionalActions.Accounts.Bootstrap`,
# so this script mostly exists for `mix ecto.setup` and for seeding a database
# without starting the app.

alias HllConditionalActions.Accounts

:ok = Accounts.bootstrap!()

%{username: username, password: password} = Accounts.bootstrap_credentials()

if Accounts.get_user_by_username(username).must_change_password? do
  IO.puts("""

  Sign in with:

      username: #{username}
      password: #{password}

  You will be asked to choose a new password straight away.
  """)
end
