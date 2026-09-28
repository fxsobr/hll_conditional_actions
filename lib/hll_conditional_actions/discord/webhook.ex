defmodule HllConditionalActions.Discord.Webhook do
  @moduledoc """
  A Discord webhook rules can post to.

  The URL embeds the webhook's token - anybody holding it can post as the
  webhook - so it is stored encrypted and never leaves this row: rules refer
  to the webhook by id, and exports refer to it by name.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Encrypted

  @type t :: %__MODULE__{}

  # Only Discord's own webhook endpoint is accepted. Any other URL would let
  # this server be pointed at whatever address a rule author chose.
  @discord_hosts ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"]

  schema "discord_webhooks" do
    field :name, :string
    field :url, Encrypted.Binary, redact: true
    field :username, :string
    field :avatar_url, :string
    field :remote_name, :string
    field :channel_id, :string
    field :guild_id, :string
    field :last_error, :string
    field :last_error_at, :utc_datetime
    field :last_delivered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or editing a webhook.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :url, :username, :avatar_url])
    |> update_change(:name, &String.trim/1)
    |> update_change(:url, &String.trim/1)
    |> validate_required([:name, :url])
    |> validate_length(:name, max: 80)
    |> validate_length(:username, max: 80)
    |> validate_change(:url, fn :url, url ->
      if url?(url), do: [], else: [url: "must be a Discord webhook URL"]
    end)
    |> validate_change(:avatar_url, fn :avatar_url, url ->
      if https?(url), do: [], else: [avatar_url: "must be an https:// address"]
    end)
    |> unique_constraint(:name)
  end

  @doc """
  Records what Discord reported about the webhook, or why it could not be
  reached.
  """
  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(webhook, attrs) do
    cast(webhook, attrs, [
      :remote_name,
      :channel_id,
      :guild_id,
      :last_error,
      :last_error_at,
      :last_delivered_at
    ])
  end

  @doc """
  Whether `url` is a Discord webhook endpoint
  (`https://discord.com/api/webhooks/{id}/{token}`).

      iex> HllConditionalActions.Discord.Webhook.url?("https://discord.com/api/webhooks/1/abc")
      true

      iex> HllConditionalActions.Discord.Webhook.url?("https://example.com/api/webhooks/1/abc")
      false
  """
  @spec url?(String.t()) :: boolean()
  def url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: "/api/" <> path, userinfo: nil, port: 443}
      when host in @discord_hosts ->
        path
        |> String.replace_prefix("v10/", "")
        |> String.split("/")
        |> case do
          ["webhooks", id, token] -> id =~ ~r/^\d+$/ and token != ""
          _other -> false
        end

      _other ->
        false
    end
  end

  def url?(_url), do: false

  @doc """
  Whether `url` is a plain `https://` address, as Discord requires for
  avatars and images.
  """
  @spec https?(String.t()) :: boolean()
  def https?(url) when is_binary(url) do
    match?(%URI{scheme: "https", host: host} when is_binary(host) and host != "", URI.parse(url))
  end

  def https?(_url), do: false
end
