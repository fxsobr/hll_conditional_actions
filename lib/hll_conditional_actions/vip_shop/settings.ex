defmodule HllConditionalActions.VipShop.Settings do
  @moduledoc """
  The shop's single row of configuration: how it presents itself, how
  customers sign in, how it sends email and what a repeat purchase does.

  ## Repeat purchases

  CRCON replaces a VIP's expiry when it is granted again, so what a second
  purchase means is decided here:

    * `"extend"` - the new days are added to what is left
    * `"replace"` - the VIP runs for the package's days from now
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias HllConditionalActions.Encrypted

  @type t :: %__MODULE__{}

  @stackings ~w(extend replace)
  @tls_modes ~w(starttls ssl none)
  @email_providers ~w(smtp sendgrid brevo)

  # The social networks the storefront can link to, in display order.
  @social_networks ~w(discord instagram youtube twitch tiktok x facebook website)

  schema "vip_shop_settings" do
    field :shop_title, :string
    field :shop_description, :string
    field :shop_subtitle, :string
    field :accent_color, :string, default: "#16a34a"
    field :logo_asset_id, :integer
    field :banner_asset_id, :integer
    field :social_links, :map, default: %{}
    field :footer_text, :string
    field :show_servers, :boolean, default: true
    field :currency, :string, default: "BRL"
    field :stacking, :string, default: "extend"
    field :password_login, :boolean, default: true
    field :discord_login, :boolean, default: false
    field :discord_client_id, :string
    field :discord_client_secret, Encrypted.Binary, redact: true
    field :email_provider, :string, default: "smtp"
    field :email_api_key, Encrypted.Binary, redact: true
    field :smtp_host, :string
    field :smtp_port, :integer
    field :smtp_username, :string
    field :smtp_password, Encrypted.Binary, redact: true
    field :smtp_tls, :string, default: "starttls"
    field :mail_from_name, :string
    field :mail_from_address, :string
    field :email_templates, :map, default: %{}
    field :reminder_days, :integer, default: 3
    field :design, :map, default: %{}
    field :alert_webhook_id, :integer
    # The storefront being edited; `design` is what the public page shows.
    field :design_draft, :map
    field :closed, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "The repeat purchase modes."
  @spec stackings() :: [String.t()]
  def stackings, do: @stackings

  @doc "The email services the shop can send through."
  @spec email_providers() :: [String.t()]
  def email_providers, do: @email_providers

  @doc "The SMTP encryption modes."
  @spec tls_modes() :: [String.t()]
  def tls_modes, do: @tls_modes

  @doc "The social networks the storefront can link to."
  @spec social_networks() :: [String.t()]
  def social_networks, do: @social_networks

  @doc """
  Changes to purchase behaviour: the currency and what a repeat purchase does.
  """
  def general_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:currency, :stacking, :reminder_days, :alert_webhook_id])
    |> update_change(:currency, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:currency, :stacking])
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> validate_inclusion(:stacking, @stackings)
    |> validate_number(:reminder_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 30)
  end

  @doc "Replaces the storefront design (see `HllConditionalActions.VipShop.Design`)."
  def design_changeset(settings, design) when is_map(design), do: change(settings, design: design)

  @doc """
  Changes to how the public page looks: names, texts, colour, images and
  social links. Only https links are kept.
  """
  def page_changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :shop_title,
      :shop_subtitle,
      :shop_description,
      :footer_text,
      :accent_color,
      :show_servers,
      :logo_asset_id,
      :banner_asset_id
    ])
    |> validate_length(:shop_title, max: 80)
    |> validate_length(:shop_subtitle, max: 160)
    |> validate_length(:shop_description, max: 4000)
    |> validate_length(:footer_text, max: 1000)
    |> validate_format(:accent_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a colour like #16a34a"
    )
    |> put_social_links(Map.get(attrs, "social_links") || Map.get(attrs, :social_links))
  end

  defp put_social_links(changeset, nil), do: changeset

  defp put_social_links(changeset, links) when is_map(links) do
    {kept, errors} =
      Enum.reduce(@social_networks, {%{}, []}, fn network, {kept, errors} ->
        case links |> Map.get(network, "") |> to_string() |> String.trim() do
          "" -> {kept, errors}
          "https://" <> _rest = url -> {Map.put(kept, network, url), errors}
          _other -> {kept, [network | errors]}
        end
      end)

    changeset = put_change(changeset, :social_links, kept)

    case errors do
      [] ->
        changeset

      networks ->
        add_error(
          changeset,
          :social_links,
          "must start with https:// (#{Enum.join(Enum.reverse(networks), ", ")})"
        )
    end
  end

  @doc """
  Changes to the sign in methods. A blank secret keeps the stored one, so the
  form never has to show it.
  """
  def login_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:password_login, :discord_login, :discord_client_id, :discord_client_secret])
    |> keep_secret(:discord_client_secret)
    |> validate_one_login()
    |> validate_discord()
  end

  @doc """
  Changes to the email service: an SMTP server, or SendGrid / Brevo with an
  API key. Blank secrets keep the stored ones.
  """
  def email_changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :email_provider,
      :email_api_key,
      :smtp_host,
      :smtp_port,
      :smtp_username,
      :smtp_password,
      :smtp_tls,
      :mail_from_name,
      :mail_from_address
    ])
    |> keep_secret(:smtp_password)
    |> keep_secret(:email_api_key)
    |> validate_inclusion(:email_provider, @email_providers)
    |> validate_inclusion(:smtp_tls, @tls_modes)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_format(:mail_from_address, ~r/^[^\s@]+@[^\s@]+$/)
  end

  @doc """
  Changes to one or more email templates.
  """
  def templates_changeset(settings, templates) when is_map(templates) do
    change(settings, email_templates: Map.merge(settings.email_templates || %{}, templates))
  end

  @doc "Whether outgoing email is configured."
  @spec email_configured?(t()) :: boolean()
  def email_configured?(%__MODULE__{email_provider: "smtp"} = s) do
    present?(s.smtp_host) and present?(s.mail_from_address)
  end

  def email_configured?(%__MODULE__{} = s) do
    present?(s.email_api_key) and present?(s.mail_from_address)
  end

  @doc "Whether Discord sign in can be offered."
  @spec discord_ready?(t()) :: boolean()
  def discord_ready?(%__MODULE__{} = s) do
    s.discord_login and present?(s.discord_client_id) and present?(s.discord_client_secret)
  end

  defp keep_secret(changeset, field) do
    case get_change(changeset, field) do
      blank when blank in [nil, ""] -> delete_change(changeset, field)
      _secret -> changeset
    end
  end

  defp validate_one_login(changeset) do
    if get_field(changeset, :password_login) or get_field(changeset, :discord_login),
      do: changeset,
      else: add_error(changeset, :password_login, "keep at least one way to sign in")
  end

  defp validate_discord(changeset) do
    if get_field(changeset, :discord_login),
      do:
        changeset
        |> validate_required([:discord_client_id])
        |> require_secret(:discord_client_secret),
      else: changeset
  end

  # A secret kept from before is not a change, so validate_required cannot
  # see it.
  defp require_secret(changeset, field) do
    if present?(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, "can't be blank")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
