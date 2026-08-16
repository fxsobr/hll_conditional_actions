defmodule HllConditionalActions.AccountsTest do
  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Accounts
  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.Role

  doctest HllConditionalActions.Accounts.Permission
  doctest HllConditionalActions.Accounts.Role

  describe "bootstrap!/0" do
    test "creates the built-in roles and the first administrator" do
      assert :ok = Accounts.bootstrap!()

      assert Enum.map(Accounts.list_roles(), & &1.name) |> Enum.sort() ==
               ["Administrator", "Operator", "Viewer"]

      admin = Accounts.get_user_by_username("admin")
      assert admin.must_change_password?
      assert admin.role.name == "Administrator"
    end

    test "the initial credentials are admin / admin" do
      assert :ok = Accounts.bootstrap!()
      %{username: username, password: password} = Accounts.bootstrap_credentials()

      assert {:ok, user} = Accounts.authenticate(username, password)
      assert user.username == "admin"
    end

    test "is idempotent and does not recreate the admin once others exist" do
      assert :ok = Accounts.bootstrap!()
      assert :ok = Accounts.bootstrap!()

      assert length(Accounts.list_users()) == 1
      assert length(Accounts.list_roles()) == 3
    end

    test "does not overwrite a customized built-in role" do
      assert :ok = Accounts.bootstrap!()

      viewer = Enum.find(Accounts.list_roles(), &(&1.name == "Viewer"))
      {:ok, _role} = Accounts.update_role(viewer, %{permissions: ["view_servers"]})

      assert :ok = Accounts.bootstrap!()

      assert Enum.find(Accounts.list_roles(), &(&1.name == "Viewer")).permissions ==
               ["view_servers"]
    end
  end

  describe "authenticate/2" do
    setup do
      %{
        user:
          user_fixture(%{
            username: "ana",
            password: "supersecret123",
            password_confirmation: "supersecret123"
          })
      }
    end

    test "accepts the right password", %{user: user} do
      assert {:ok, authenticated} = Accounts.authenticate("ana", "supersecret123")
      assert authenticated.id == user.id
    end

    test "the username is case insensitive" do
      assert {:ok, _user} = Accounts.authenticate("ANA", "supersecret123")
    end

    test "rejects a wrong password" do
      assert {:error, :invalid_credentials} = Accounts.authenticate("ana", "wrong")
    end

    test "rejects an unknown username without leaking that it is unknown" do
      assert {:error, :invalid_credentials} = Accounts.authenticate("nobody", "supersecret123")
    end

    test "rejects a deactivated account even with the right password", %{user: user} do
      {:ok, _user} = Accounts.update_user(user, %{active: false})

      assert {:error, :invalid_credentials} = Accounts.authenticate("ana", "supersecret123")
    end

    test "records the sign in time", %{user: user} do
      refute user.last_login_at
      assert {:ok, authenticated} = Accounts.authenticate("ana", "supersecret123")
      assert authenticated.last_login_at
    end
  end

  describe "permissions" do
    test "manage implies view" do
      role = role_fixture(%{permissions: ["manage_servers"]})
      user = user_fixture(%{role: role})

      assert Accounts.can?(user, :manage_servers)
      assert Accounts.can?(user, :view_servers)
      refute Accounts.can?(user, :manage_rules)
    end

    test "an anonymous or deactivated user can do nothing" do
      user = user_fixture(%{role: role_fixture(%{permissions: Permission.all_strings()})})
      {:ok, inactive} = Accounts.update_user(user, %{active: false})

      refute Accounts.can?(nil, :view_servers)
      refute Accounts.can?(inactive, :view_servers)
    end

    test "unknown permission names are dropped when saving a role" do
      role = role_fixture(%{permissions: ["view_servers", "launch_missiles", "false", ""]})

      assert role.permissions == ["view_servers"]
    end
  end

  describe "users" do
    test "a password is required on create but optional on update" do
      role = Accounts.ensure_system_roles!().viewer

      assert {:error, changeset} = Accounts.create_user(%{username: "bob", role_id: role.id})
      assert %{password: ["can't be blank"]} = errors_on(changeset)

      user = user_fixture()
      assert {:ok, updated} = Accounts.update_user(user, %{name: "New Name"})
      assert updated.hashed_password == user.hashed_password
    end

    test "usernames are unique and normalized" do
      user_fixture(%{username: "carol"})

      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: "CAROL",
                 password: "supersecret123",
                 role_id: Accounts.ensure_system_roles!().viewer.id
               })

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "passwords must be at least 8 characters" do
      assert {:error, changeset} =
               Accounts.create_user(%{
                 username: "dave",
                 password: "short",
                 role_id: Accounts.ensure_system_roles!().viewer.id
               })

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
    end

    test "changing a password clears the forced change flag" do
      user = user_fixture(%{must_change_password?: true})

      assert {:ok, updated} =
               Accounts.update_password(user, %{
                 password: "brandnewpassword",
                 password_confirmation: "brandnewpassword"
               })

      refute updated.must_change_password?
      assert {:ok, _user} = Accounts.authenticate(user.username, "brandnewpassword")
    end

    test "the last account that can manage users cannot be deleted" do
      admin = user_fixture()

      assert Accounts.last_administrator?(admin)
      assert {:error, :last_administrator} = Accounts.delete_user(admin)
    end

    test "an administrator can be deleted once another one exists" do
      admin = user_fixture()
      _second = user_fixture()

      assert {:ok, _user} = Accounts.delete_user(admin)
    end
  end

  describe "roles" do
    test "built-in roles cannot be deleted" do
      %{viewer: viewer} = Accounts.ensure_system_roles!()

      assert {:error, :system_role} = Accounts.delete_role(viewer)
    end

    test "a role still in use cannot be deleted" do
      role = role_fixture()
      _user = user_fixture(%{role: role})

      assert {:error, :role_in_use} = Accounts.delete_role(role)
    end

    test "an unused custom role can be deleted" do
      role = role_fixture()

      assert {:ok, %Role{}} = Accounts.delete_role(role)
    end
  end
end
