defmodule HllConditionalActionsWeb.UserAuth do
  @moduledoc """
  Session authentication and permission checks.

  Sign in stores the user id in the session, and every request or LiveView
  mount reloads the user so a revoked role or a deactivated account takes
  effect immediately rather than at the next login.

  ## Using it in the router

      live_session :authenticated,
        on_mount: [{HllConditionalActionsWeb.UserAuth, :ensure_authenticated}] do
        live "/servers", ServerLive.Index, :index
      end

  ## Using it for a permission

      live_session :servers,
        on_mount: [{HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_servers}}] do
        live "/servers/new", ServerLive.Form, :new
      end
  """

  use HllConditionalActionsWeb, :verified_routes

  use Gettext, backend: HllConditionalActionsWeb.Gettext

  import Phoenix.Controller
  import Plug.Conn

  alias HllConditionalActions.Accounts
  alias Phoenix.Component
  alias Phoenix.LiveView

  @session_key :user_id
  @return_to_key :user_return_to
  # Set between the password and the code. Holding the id here rather than in
  # `@session_key` is the whole point: a half signed in visitor must reach
  # nothing, and every page reads `@session_key`.
  @pending_key :pending_user_id
  # A code prompt left open all night is not a session anybody asked for.
  @pending_ttl_seconds 300

  # ── Plugs ──────────────────────────────────────────────────────────────────

  @doc """
  Loads the signed in user into `conn.assigns.current_user`.
  """
  def fetch_current_user(conn, _opts) do
    user = conn |> get_session(@session_key) |> Accounts.get_user()
    assign(conn, :current_user, active_user(user))
  end

  @doc """
  Sends anonymous visitors to the login page.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, gettext("Please sign in to continue."))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Keeps a signed in user away from the login page.
  """
  def redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: ~p"/") |> halt()
    else
      conn
    end
  end

  @doc """
  Signs a user in, rotating the session to prevent fixation.
  """
  def log_in_user(conn, user) do
    return_to = get_session(conn, @return_to_key)

    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> redirect(to: return_to || signed_in_path(user))
  end

  @doc """
  Records that the password was right but the second factor is still owed.

  The session is rotated here as well as at `log_in_user/2`, so the id a
  visitor arrived with never survives the password step either.
  """
  def start_two_factor(conn, user) do
    return_to = get_session(conn, @return_to_key)

    conn
    |> renew_session()
    |> put_session(@pending_key, user.id)
    |> put_session(:pending_since, System.system_time(:second))
    |> put_session(@return_to_key, return_to)
    |> redirect(to: ~p"/login/code")
  end

  @doc """
  The user who is halfway through signing in, or `nil`.

  Expires by itself: a browser left on the code prompt overnight is asked for
  the password again rather than being handed a second chance in the morning.
  """
  def pending_user(conn) do
    with id when not is_nil(id) <- get_session(conn, @pending_key),
         since when is_integer(since) <- get_session(conn, :pending_since),
         true <- System.system_time(:second) - since < @pending_ttl_seconds do
      conn |> get_session(@pending_key) |> Accounts.get_user() |> active_user()
    else
      _expired -> nil
    end
  end

  @doc """
  Sends anyone without a half finished sign in back to the password form.
  """
  def require_pending_user(conn, _opts) do
    case pending_user(conn) do
      nil ->
        conn
        |> put_flash(:error, gettext("Please sign in to continue."))
        |> redirect(to: ~p"/login")
        |> halt()

      user ->
        assign(conn, :pending_user, user)
    end
  end

  @doc """
  Signs the current user out and drops their LiveView connections.
  """
  def log_out_user(conn) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      HllConditionalActionsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  @doc """
  Where a user lands after signing in.

  Somebody still on the bootstrap password goes straight to the password form;
  everything else is behind that.
  """
  def signed_in_path(%{must_change_password?: true}), do: ~p"/account/password"
  def signed_in_path(_user), do: ~p"/"

  # ── LiveView hooks ─────────────────────────────────────────────────────────

  @doc """
  `on_mount` hooks for `live_session`.

    * `:mount_current_user` - assigns `@current_user`, allows anonymous access
    * `:ensure_authenticated` - redirects anonymous visitors to the login page
    * `{:ensure_permission, permission}` - also requires a permission
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:halt, redirect_to_login(socket)}

      socket.assigns.current_user.must_change_password? ->
        {:halt, require_password_change(socket)}

      true ->
        {:cont, socket}
    end
  end

  def on_mount({:ensure_permission, permission}, params, session, socket) do
    case on_mount(:ensure_authenticated, params, session, socket) do
      {:cont, socket} ->
        if Accounts.can?(socket.assigns.current_user, permission) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> LiveView.put_flash(:error, gettext("You do not have access to that page."))
           |> LiveView.redirect(to: ~p"/")}
        end

      halted ->
        halted
    end
  end

  # The password form is the one authenticated page a user with an expired
  # password may open, otherwise they could never clear the flag.
  def on_mount(:ensure_authenticated_allow_password_change, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect_to_login(socket)}
    end
  end

  defp mount_current_user(socket, session) do
    Component.assign_new(socket, :current_user, fn ->
      session |> Map.get(to_string(@session_key)) |> Accounts.get_user() |> active_user()
    end)
  end

  defp redirect_to_login(socket) do
    socket
    |> LiveView.put_flash(:error, gettext("Please sign in to continue."))
    |> LiveView.redirect(to: ~p"/login")
  end

  defp require_password_change(socket) do
    socket
    |> LiveView.put_flash(:info, gettext("Choose a new password before continuing."))
    |> LiveView.redirect(to: ~p"/account/password")
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp active_user(%{active: true} = user), do: user
  defp active_user(_user), do: nil

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, @return_to_key, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
