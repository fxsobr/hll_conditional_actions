defmodule HllConditionalActions.Accounts do
  @moduledoc """
  Users, roles and authentication.

  Access is role based: a user has exactly one role, and a role carries a list
  of `HllConditionalActions.Accounts.Permission` names. Everything the UI and
  the router allow is decided by `can?/2`.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts.Permission
  alias HllConditionalActions.Accounts.Role
  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers.Server

  @doc """
  The username and password the very first login uses.

  Both are `admin`. The account is created with
  `must_change_password?` set, so the app forces a new password before letting
  it do anything else.
  """
  @spec bootstrap_credentials() :: %{username: String.t(), password: String.t()}
  def bootstrap_credentials, do: %{username: "admin", password: "admin"}

  # ── Authentication ─────────────────────────────────────────────────────────

  @doc """
  Returns the user for a username and password, or `nil`.

  Inactive accounts never authenticate, even with the right password.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate(username, password) do
    user = get_user_by_username(username)

    cond do
      not User.valid_password?(user, password) -> {:error, :invalid_credentials}
      not user.active -> {:error, :invalid_credentials}
      true -> {:ok, touch_login(user)}
    end
  end

  @doc """
  Fetches a user by username, with their role preloaded.
  """
  @spec get_user_by_username(String.t() | nil) :: User.t() | nil
  def get_user_by_username(nil), do: nil

  def get_user_by_username(username) do
    normalized = username |> to_string() |> String.trim() |> String.downcase()

    User
    |> where([u], u.username == ^normalized)
    |> preload([:role, :servers])
    |> Repo.one()
  end

  @doc """
  Fetches a user by id, with their role preloaded, or `nil`.
  """
  @spec get_user(term()) :: User.t() | nil
  def get_user(nil), do: nil
  def get_user(id), do: User |> Repo.get(id) |> Repo.preload([:role, :servers])

  @doc """
  Fetches a user by id, raising if missing.
  """
  @spec get_user!(term()) :: User.t()
  def get_user!(id), do: User |> Repo.get!(id) |> Repo.preload([:role, :servers])

  @doc """
  Whether a user is allowed to do something.

      iex> alias HllConditionalActions.Accounts
      iex> Accounts.can?(nil, :view_servers)
      false
  """
  @spec can?(User.t() | nil, atom() | String.t()) :: boolean()
  def can?(nil, _permission), do: false
  def can?(%User{active: false}, _permission), do: false
  def can?(%User{role: %Role{} = role}, permission), do: Role.can?(role, permission)
  def can?(%User{}, _permission), do: false

  # ── Server scope ───────────────────────────────────────────────────────────

  @doc """
  Whether a user is limited to a subset of the servers.

  No assignment means no restriction, so a fresh install works without anyone
  having to configure scope.
  """
  @spec restricted?(User.t() | nil) :: boolean()
  def restricted?(%User{servers: servers}) when is_list(servers), do: servers != []
  def restricted?(_user), do: false

  @doc """
  The servers a user may reach: `:all`, or the ids they are assigned to.

      iex> alias HllConditionalActions.Accounts
      iex> Accounts.server_scope(%HllConditionalActions.Accounts.User{servers: []})
      :all
  """
  @spec server_scope(User.t() | nil) :: :all | [term()]
  def server_scope(%User{} = user) do
    if restricted?(user), do: Enum.map(user.servers, & &1.id), else: :all
  end

  def server_scope(_user), do: :all

  @doc """
  Whether a user may see and act on a server.
  """
  @spec can_access_server?(User.t() | nil, term()) :: boolean()
  def can_access_server?(user, server_or_id) do
    case server_scope(user) do
      :all -> true
      ids -> server_id(server_or_id) in ids
    end
  end

  @doc """
  Replaces the servers a user is restricted to. An empty list lifts the
  restriction.
  """
  @spec set_user_servers(User.t(), [term()]) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_user_servers(%User{} = user, server_ids) do
    servers =
      case Enum.reject(server_ids, &(&1 in [nil, ""])) do
        [] -> []
        ids -> Repo.all(from s in Server, where: s.id in ^Enum.map(ids, &cast_id/1))
      end

    user
    |> Repo.preload(:servers)
    |> User.servers_changeset(servers)
    |> Repo.update()
    |> preload_role()
  end

  defp server_id(%Server{id: id}), do: id
  defp server_id(id), do: cast_id(id)

  defp cast_id(id) when is_integer(id), do: id

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> id
    end
  end

  defp cast_id(id), do: id

  # ── Users ──────────────────────────────────────────────────────────────────

  @doc """
  Lists users with their roles, alphabetically.
  """
  @spec list_users() :: [User.t()]
  def list_users do
    User |> order_by([u], asc: u.username) |> preload([:role, :servers]) |> Repo.all()
  end

  @doc """
  Creates a user.
  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
    |> preload_role()
  end

  @doc """
  Updates a user.
  """
  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
    |> preload_role()
  end

  @doc """
  Deletes a user.

  Refuses to delete the last account that can manage users, which would lock
  everyone out of the platform.
  """
  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, :last_administrator}
  def delete_user(%User{} = user) do
    if last_administrator?(user) do
      {:error, :last_administrator}
    else
      Repo.delete(user)
    end
  end

  @doc """
  Changes a user's own password.
  """
  @spec update_password(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
    |> preload_role()
  end

  @doc """
  Updates a user's own profile.
  """
  @spec update_profile(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
    |> preload_role()
  end

  @doc """
  Builds a changeset for a user form.
  """
  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc """
  Builds a changeset for the profile form a user edits about themselves.
  """
  @spec update_profile_changeset(User.t(), map()) :: Ecto.Changeset.t()
  def update_profile_changeset(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc """
  Builds a changeset for the change-password form.
  """
  @spec change_password(User.t(), map()) :: Ecto.Changeset.t()
  def change_password(%User{} = user, attrs \\ %{}), do: User.password_changeset(user, attrs)

  @doc """
  Whether this user is the only remaining account that can manage users.
  """
  @spec last_administrator?(User.t()) :: boolean()
  def last_administrator?(%User{} = user) do
    if can?(Repo.preload(user, :role), :manage_users) do
      administrator_count() <= 1
    else
      false
    end
  end

  # ── Roles ──────────────────────────────────────────────────────────────────

  @doc """
  Lists roles, alphabetically.
  """
  @spec list_roles() :: [Role.t()]
  def list_roles, do: Role |> order_by([r], asc: r.name) |> Repo.all()

  @doc """
  Lists roles as `{name, id}` tuples for a `<select>` input.
  """
  @spec role_options() :: [{String.t(), term()}]
  def role_options, do: Enum.map(list_roles(), &{&1.name, &1.id})

  @doc """
  Fetches a role, raising if missing.
  """
  @spec get_role!(term()) :: Role.t()
  def get_role!(id), do: Repo.get!(Role, id)

  @doc """
  Creates a role.
  """
  @spec create_role(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create_role(attrs) do
    %Role{} |> Role.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Updates a role.
  """
  @spec update_role(Role.t(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def update_role(%Role{} = role, attrs) do
    role |> Role.changeset(attrs) |> Repo.update()
  end

  @doc """
  Deletes a role.

  System roles and roles still assigned to somebody cannot be deleted.
  """
  @spec delete_role(Role.t()) ::
          {:ok, Role.t()} | {:error, :system_role | :role_in_use | Ecto.Changeset.t()}
  def delete_role(%Role{system?: true}), do: {:error, :system_role}

  def delete_role(%Role{} = role) do
    if users_with_role(role.id) > 0 do
      {:error, :role_in_use}
    else
      Repo.delete(role)
    end
  end

  @doc """
  Builds a changeset for a role form.
  """
  @spec change_role(Role.t(), map()) :: Ecto.Changeset.t()
  def change_role(%Role{} = role, attrs \\ %{}), do: Role.changeset(role, attrs)

  @doc """
  How many users hold a role.
  """
  @spec users_with_role(term()) :: non_neg_integer()
  def users_with_role(role_id) do
    Repo.one(from u in User, where: u.role_id == ^role_id, select: count(u.id))
  end

  # ── Bootstrap ──────────────────────────────────────────────────────────────

  @doc """
  Creates the seed roles and, if there are no users at all, the initial
  `admin` / `admin` account.

  Runs on every boot and is idempotent, so a fresh database (a new deployment,
  a `mix ecto.reset`, a container with an empty volume) always ends up with a
  way in.
  """
  @spec bootstrap!() :: :ok
  def bootstrap! do
    roles = ensure_system_roles!()

    if Repo.aggregate(User, :count, :id) == 0 do
      %{username: username, password: password} = bootstrap_credentials()

      %User{}
      |> User.bootstrap_changeset(%{
        username: username,
        name: "Administrator",
        password: password,
        role_id: roles.administrator.id
      })
      # `mix ecto.setup` runs the seed script while the boot task is doing the
      # same thing, so both can see an empty table. Letting the database settle
      # the race is simpler than coordinating them.
      |> Repo.insert(on_conflict: :nothing, conflict_target: :username)
    end

    :ok
  end

  @doc """
  Creates the built-in roles if they are missing and returns them.
  """
  @spec ensure_system_roles!() :: %{administrator: Role.t(), operator: Role.t(), viewer: Role.t()}
  def ensure_system_roles! do
    %{
      administrator:
        upsert_system_role!(
          "Administrator",
          "Full access, including user and role management.",
          Permission.all_strings()
        ),
      operator:
        upsert_system_role!(
          "Operator",
          "Writes rules and watches what they do. Cannot change server credentials or access.",
          ~w(view_servers manage_rules view_executions view_live_feed)
        ),
      viewer:
        upsert_system_role!(
          "Viewer",
          "Read only access to servers, rules and history.",
          ~w(view_servers view_rules view_executions view_live_feed)
        )
    }
  end

  # Only the permissions of a *missing* role are written. An operator who
  # tailors the built-in roles keeps their changes across restarts.
  defp upsert_system_role!(name, description, permissions) do
    case Repo.get_by(Role, name: name) do
      nil ->
        %Role{system?: true}
        |> Role.changeset(%{name: name, description: description, permissions: permissions})
        |> Repo.insert!()

      role ->
        role
    end
  end

  defp administrator_count do
    Repo.one(
      from u in User,
        join: r in assoc(u, :role),
        where: u.active == true and "manage_users" in r.permissions,
        select: count(u.id)
    )
  end

  defp touch_login(user) do
    case user |> User.login_changeset() |> Repo.update() do
      {:ok, updated} -> %{updated | role: user.role}
      {:error, _changeset} -> user
    end
  end

  defp preload_role({:ok, user}), do: {:ok, Repo.preload(user, [:role, :servers], force: true)}
  defp preload_role(other), do: other
end
