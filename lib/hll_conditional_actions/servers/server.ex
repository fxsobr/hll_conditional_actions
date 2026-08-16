defmodule HllConditionalActions.Servers.Server do
  @moduledoc """
  A CRCON deployment this application drives.

  Each CRCON instance serves exactly one game server and is configured for one
  game (`HLL_GAME=hll` or `hllv`), so `game` decides which
  `HllConditionalActions.Games.Profile` applies to everything below it.

  The API key is stored encrypted (`HllConditionalActions.Encrypted.Binary`)
  and marked `redact: true` so it never leaks into logs or inspect output.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Encrypted
  alias HllConditionalActions.Games
  alias HllConditionalActions.Rules.Rule

  @type t :: %__MODULE__{}

  schema "servers" do
    field :name, :string
    field :game, Ecto.Enum, values: [:hll, :hllv], default: :hll
    field :base_url, :string
    field :api_key, Encrypted.Binary, redact: true
    field :enabled, :boolean, default: true
    field :log_stream_enabled, :boolean, default: true
    # IANA zone of the community this server serves. Time-of-day conditions are
    # evaluated against it, so "after 22:00" means the players' evening.
    field :timezone, :string, default: "Etc/UTC"
    field :notes, :string
    # What the API key was last seen to be allowed to do, so a rule can warn
    # that one of its actions can never work here. Refreshed by the connection
    # test; empty means never checked.
    field :known_permissions, {:array, :string}, default: []
    field :permissions_checked_at, :utc_datetime

    has_many :rules, Rule

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating a server.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :game,
      :base_url,
      :api_key,
      :enabled,
      :log_stream_enabled,
      :timezone,
      :notes,
      :known_permissions,
      :permissions_checked_at
    ])
    |> update_change(:base_url, &normalize_base_url/1)
    |> update_change(:api_key, &trim/1)
    |> validate_required([:name, :game, :base_url, :api_key])
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:game, Games.all())
    |> validate_base_url()
    |> validate_timezone()
    |> unique_constraint(:name)
  end

  @doc """
  The server's IANA time zone, falling back to UTC when it is unset or no
  longer known to the time zone database.
  """
  @spec timezone(t()) :: String.t()
  def timezone(%__MODULE__{timezone: zone}) do
    if known_timezone?(zone), do: zone, else: "Etc/UTC"
  end

  @doc """
  Time zones offered in the server form.

  A curated list rather than all ~600 IANA zones: these cover where Hell Let
  Loose communities actually are, and a zone outside it can still be stored -
  `changeset/2` accepts any zone the database resolves.
  """
  @spec common_timezones() :: [String.t()]
  def common_timezones do
    ~w(
      Etc/UTC
      America/Sao_Paulo
      America/Argentina/Buenos_Aires
      America/New_York
      America/Chicago
      America/Denver
      America/Los_Angeles
      Europe/London
      Europe/Lisbon
      Europe/Madrid
      Europe/Paris
      Europe/Berlin
      Europe/Rome
      Europe/Amsterdam
      Europe/Warsaw
      Europe/Stockholm
      Europe/Helsinki
      Europe/Kyiv
      Europe/Moscow
      Australia/Perth
      Australia/Sydney
      Pacific/Auckland
    )
  end

  @doc """
  Time zone options for a `<select>`, always including the server's current
  zone even when it is not one of the common ones.
  """
  @spec timezone_options(t() | nil) :: [String.t()]
  def timezone_options(server \\ nil) do
    current = server && server.timezone

    if is_binary(current) and current not in common_timezones() do
      Enum.sort([current | common_timezones()])
    else
      common_timezones()
    end
  end

  @doc """
  Whether a string names a zone the time zone database can resolve.
  """
  @spec known_timezone?(String.t() | nil) :: boolean()
  def known_timezone?(zone) when is_binary(zone) do
    match?({:ok, _datetime}, DateTime.now(zone))
  end

  def known_timezone?(_zone), do: false

  @doc """
  The profile of the game this server runs.
  """
  @spec profile(t()) :: Games.Profile.t()
  def profile(%__MODULE__{game: game}), do: Games.profile!(game)

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, value ->
      if known_timezone?(value),
        do: [],
        else: [timezone: "is not a known time zone"]
    end)
  end

  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _invalid ->
          [base_url: "must be a full URL, for example https://rcon.example.com"]
      end
    end)
  end

  defp normalize_base_url(nil), do: nil

  defp normalize_base_url(value) do
    value |> to_string() |> String.trim() |> String.trim_trailing("/")
  end

  defp trim(nil), do: nil
  defp trim(value), do: value |> to_string() |> String.trim()
end
