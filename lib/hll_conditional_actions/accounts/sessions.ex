defmodule HllConditionalActions.Accounts.Sessions do
  @moduledoc """
  The browsers each user is signed in on.

  Signing in creates a row (`create/2`) and puts its token in the session
  cookie; every request checks the token is still known (`fetch/1`). That is
  what makes "sign out the other sessions" real: deleting a row ends that
  browser's session on its next request, and its LiveViews are disconnected
  through the row's own socket id (`socket_id/1`).

  Sessions opened before this existed carry no token. They keep working and
  are adopted - given a row - on their next page load, so they show up in the
  list like any other.
  """

  import Ecto.Query

  alias HllConditionalActions.Accounts.User
  alias HllConditionalActions.Accounts.UserSession
  alias HllConditionalActions.Repo

  @token_bytes 32

  # `last_seen_at` is only written when it is older than this, so a busy page
  # does not update the row on every request.
  @touch_after_seconds 60

  @type meta :: %{optional(:user_agent) => String.t() | nil, optional(:ip) => String.t() | nil}

  @doc """
  Opens a session for `user`, returning the token for the cookie.
  """
  @spec create(User.t() | integer(), meta()) :: {String.t(), UserSession.t()}
  def create(user, meta \\ %{})

  def create(%User{id: id}, meta), do: create(id, meta)

  def create(user_id, meta) when is_integer(user_id) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = now()

    session =
      Repo.insert!(%UserSession{
        user_id: user_id,
        token_hash: hash(token),
        user_agent: meta |> Map.get(:user_agent) |> truncate(),
        ip: meta |> Map.get(:ip) |> truncate(),
        last_seen_at: now
      })

    {token, session}
  end

  @doc """
  Gives a token to a session opened before sessions were tracked.

  Such a cookie has no token of its own, and the same cookie may arrive on
  several requests at once (tabs opening together), so the token is derived
  from something the cookie already carries and does not change - `seed`,
  the session's CSRF secret. Every request of that cookie gets the same
  token and the same row; the caller stores the token in the cookie so the
  browser carries it from then on.
  """
  @spec adopt(User.t(), meta(), String.t()) :: {String.t(), UserSession.t()}
  def adopt(%User{id: user_id}, meta, seed) when is_binary(seed) do
    token =
      :sha256
      |> :crypto.hash("legacy:#{user_id}:#{seed}")
      |> Base.url_encode64(padding: false)

    now = now()

    Repo.insert!(
      %UserSession{
        user_id: user_id,
        token_hash: hash(token),
        user_agent: meta |> Map.get(:user_agent) |> truncate(),
        ip: meta |> Map.get(:ip) |> truncate(),
        last_seen_at: now
      },
      on_conflict: :nothing,
      conflict_target: :token_hash
    )

    {token, Repo.get_by!(UserSession, token_hash: hash(token))}
  end

  @doc """
  The live session behind a token, or `nil` when it was signed out.

  Refreshes `last_seen_at` when it is more than a minute old.
  """
  @spec fetch(String.t() | nil) :: UserSession.t() | nil
  def fetch(token) when is_binary(token) do
    case Repo.get_by(UserSession, token_hash: hash(token)) do
      nil ->
        nil

      session ->
        if DateTime.diff(now(), session.last_seen_at) > @touch_after_seconds do
          from(s in UserSession, where: s.id == ^session.id)
          |> Repo.update_all(set: [last_seen_at: now()])
        end

        session
    end
  end

  def fetch(_token), do: nil

  @doc "The id of the session behind a token, without touching it."
  @spec id_for(String.t() | nil) :: integer() | nil
  def id_for(token) when is_binary(token) do
    Repo.one(from s in UserSession, where: s.token_hash == ^hash(token), select: s.id)
  end

  def id_for(_token), do: nil

  @doc "A user's sessions, the most recently seen first."
  @spec list(User.t() | integer()) :: [UserSession.t()]
  def list(%User{id: id}), do: list(id)

  def list(user_id) do
    Repo.all(
      from s in UserSession,
        where: s.user_id == ^user_id,
        order_by: [desc: s.last_seen_at, desc: s.id]
    )
  end

  @doc "How many sessions each user has open, by user id."
  @spec counts() :: %{integer() => non_neg_integer()}
  def counts do
    from(s in UserSession, group_by: s.user_id, select: {s.user_id, count(s.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Signs one of a user's sessions out. Returns the ids that were removed.
  """
  @spec revoke(User.t() | integer(), integer()) :: [integer()]
  def revoke(%User{id: id}, session_id), do: revoke(id, session_id)

  def revoke(user_id, session_id) do
    delete(from s in UserSession, where: s.user_id == ^user_id and s.id == ^session_id)
  end

  @doc """
  Signs out every session of a user except `keep_id` (the one asking).
  """
  @spec revoke_others(User.t() | integer(), integer() | nil) :: [integer()]
  def revoke_others(%User{id: id}, keep_id), do: revoke_others(id, keep_id)

  def revoke_others(user_id, nil), do: revoke_all(user_id)

  def revoke_others(user_id, keep_id) do
    delete(from s in UserSession, where: s.user_id == ^user_id and s.id != ^keep_id)
  end

  @doc "Signs out every session of a user."
  @spec revoke_all(User.t() | integer()) :: [integer()]
  def revoke_all(%User{id: id}), do: revoke_all(id)

  def revoke_all(user_id), do: delete(from s in UserSession, where: s.user_id == ^user_id)

  @doc "Removes the session behind a token, at sign out."
  @spec delete_token(String.t() | nil) :: :ok
  def delete_token(token) when is_binary(token) do
    Repo.delete_all(from s in UserSession, where: s.token_hash == ^hash(token))
    :ok
  end

  def delete_token(_token), do: :ok

  @doc """
  The LiveView socket id of a session, so it can be disconnected when the
  session is signed out from elsewhere.
  """
  @spec socket_id(integer()) :: String.t()
  def socket_id(session_id), do: "user_session:#{session_id}"

  @doc """
  Browser, system and kind of device read from a user agent string.

      iex> HllConditionalActions.Accounts.Sessions.describe("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36")
      %{browser: "Chrome", os: "Windows", device: :desktop}

      iex> HllConditionalActions.Accounts.Sessions.describe("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")
      %{browser: "Safari", os: "iPhone", device: :phone}
  """
  @spec describe(String.t() | nil) :: %{
          browser: String.t() | nil,
          os: String.t() | nil,
          device: :desktop | :phone | :tablet
        }
  def describe(user_agent) when is_binary(user_agent) do
    %{browser: browser(user_agent), os: os(user_agent), device: device(user_agent)}
  end

  def describe(_user_agent), do: %{browser: nil, os: nil, device: :desktop}

  # Order matters: Edge and Opera also say "Chrome", Chrome also says "Safari".
  defp browser(ua) do
    cond do
      ua =~ ~r/Edg(e|A|iOS)?\// -> "Edge"
      ua =~ ~r/OPR\/|Opera/ -> "Opera"
      ua =~ ~r/Firefox\/|FxiOS\// -> "Firefox"
      ua =~ ~r/Chrome\/|CriOS\// -> "Chrome"
      ua =~ ~r/Safari\// -> "Safari"
      true -> nil
    end
  end

  defp os(ua) do
    cond do
      ua =~ "iPhone" -> "iPhone"
      ua =~ "iPad" -> "iPad"
      ua =~ "Android" -> "Android"
      ua =~ "Windows" -> "Windows"
      ua =~ ~r/Mac OS X|Macintosh/ -> "macOS"
      ua =~ "CrOS" -> "ChromeOS"
      ua =~ "Linux" -> "Linux"
      true -> nil
    end
  end

  defp device(ua) do
    cond do
      ua =~ ~r/iPad|Tablet/ -> :tablet
      ua =~ ~r/Mobile|iPhone|Android/ -> :phone
      true -> :desktop
    end
  end

  defp delete(query) do
    {_count, ids} = Repo.delete_all(select(query, [s], s.id))
    ids
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp truncate(nil), do: nil
  defp truncate(value), do: value |> to_string() |> String.slice(0, 255)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
