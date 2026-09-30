defmodule HllConditionalActions.VipShop do
  @moduledoc """
  The VIP shop: packages sold for one or more servers, customers who buy
  them, and the VIP each paid order grants.

  ## Flow

    1. A customer signs in (email and password, or Discord), links one of the
       players CRCON knows and picks a package.
    2. `create_order/4` records a pending order and the payment provider
       returns a checkout page to send them to.
    3. The provider confirms the payment (`mark_paid/3`, from its webhook or
       the return page), which queues `HllConditionalActions.Workers.FulfillVipOrder`.
    4. The worker grants VIP on every server of the package (`fulfill/1`) and
       emails the receipt.

  The shop is a marketplace module: a package can only target servers that
  installed it, and the public page is open only while at least one has.
  """

  import Ecto.Query

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Features
  alias HllConditionalActions.PubSub
  alias HllConditionalActions.Repo
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server

  alias HllConditionalActions.VipShop.{
    Asset,
    Coupon,
    Customer,
    CustomerPlayer,
    CustomerToken,
    Design,
    Emails,
    Grant,
    Order,
    Package,
    PaymentProvider,
    Payments,
    Settings,
    Storefront,
    WebhookEvent
  }

  @topic "vip_shop"

  @doc "Subscribes to `{:vip_order, order}` as orders change."
  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  defp broadcast(%Order{} = order) do
    Phoenix.PubSub.broadcast(PubSub, @topic, {:vip_order, order})
    order
  end

  # ── Settings ───────────────────────────────────────────────────────────────

  @doc "The shop's settings, created with defaults the first time."
  @spec settings() :: Settings.t()
  def settings do
    Repo.one(from s in Settings, limit: 1) || Repo.insert!(%Settings{})
  end

  @doc "Saves one section of the settings: `:general`, `:page`, `:login` or `:email`."
  @spec update_settings(atom(), map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(section, attrs) do
    changeset =
      case section do
        :general -> Settings.general_changeset(settings(), attrs)
        :page -> Settings.page_changeset(settings(), attrs)
        :login -> Settings.login_changeset(settings(), attrs)
        :email -> Settings.email_changeset(settings(), attrs)
      end

    Repo.update(changeset)
  end

  @doc "A changeset for one section of the settings, for its form."
  @spec change_settings(atom(), map()) :: Ecto.Changeset.t()
  def change_settings(section, attrs \\ %{}) do
    case section do
      :general -> Settings.general_changeset(settings(), attrs)
      :page -> Settings.page_changeset(settings(), attrs)
      :login -> Settings.login_changeset(settings(), attrs)
      :email -> Settings.email_changeset(settings(), attrs)
    end
  end

  @doc "Saves the storefront design."
  @spec update_design(map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_design(design), do: settings() |> Settings.design_changeset(design) |> Repo.update()

  @doc """
  The storefront being edited: the saved draft, or what is published when
  there is no draft. Besides the design it carries the logo and the banner
  (`"logo_asset_id"`, `"banner_asset_id"`), which publish to their columns.
  """
  @spec design_draft(Settings.t()) :: map()
  def design_draft(%Settings{} = settings) do
    case settings.design_draft do
      nil -> published_draft(settings)
      draft -> Map.merge(Design.get(draft), Map.take(draft, ~w(logo_asset_id banner_asset_id)))
    end
  end

  defp published_draft(settings) do
    settings.design
    |> Design.get()
    |> Map.merge(%{
      "logo_asset_id" => settings.logo_asset_id,
      "banner_asset_id" => settings.banner_asset_id
    })
  end

  @doc "Keeps an edited storefront as the draft, without publishing it."
  @spec save_design_draft(map()) :: {:ok, Settings.t()}
  def save_design_draft(draft) when is_map(draft) do
    settings() |> Ecto.Changeset.change(design_draft: draft) |> Repo.update()
  end

  @doc "Publishes the draft storefront: the public page shows it from now on."
  @spec publish_design() :: {:ok, Settings.t()}
  def publish_design do
    settings = settings()
    draft = design_draft(settings)

    settings
    |> Ecto.Changeset.change(
      design: Map.drop(draft, ~w(logo_asset_id banner_asset_id)),
      logo_asset_id: draft["logo_asset_id"],
      banner_asset_id: draft["banner_asset_id"],
      design_draft: nil
    )
    |> Repo.update()
  end

  @doc "Drops the draft storefront, back to what is published."
  @spec discard_design_draft() :: {:ok, Settings.t()}
  def discard_design_draft,
    do: settings() |> Ecto.Changeset.change(design_draft: nil) |> Repo.update()

  @doc """
  How many parts of the draft differ from the published storefront: the
  theme, the accent, each image, the hero title, each section (its switch,
  place or title) and the benefits and questions lists.
  """
  @spec unpublished_changes(Settings.t()) :: non_neg_integer()
  def unpublished_changes(%Settings{design_draft: nil}), do: 0

  def unpublished_changes(%Settings{} = settings) do
    draft = design_draft(settings)
    live = published_draft(settings)

    simple =
      Enum.count(
        ~w(theme accent hero uppercase cta_label logo_asset_id banner_asset_id benefits faq auth),
        &(draft[&1] != live[&1])
      )

    hero =
      if get_in(draft, ["titles", "hero"]) != get_in(live, ["titles", "hero"]), do: 1, else: 0

    sections =
      Enum.count(Design.section_keys(), &(section_state(draft, &1) != section_state(live, &1)))

    simple + hero + sections
  end

  defp section_state(design, key) do
    index = Enum.find_index(design["sections"], &(&1["key"] == key))
    enabled = Enum.find_value(design["sections"], &(&1["key"] == key && &1["enabled"]))
    {index, enabled, get_in(design, ["titles", key])}
  end

  @doc "Closes the public page (visitors are turned away) or opens it again."
  @spec set_closed(boolean()) :: {:ok, Settings.t()}
  def set_closed(closed) when is_boolean(closed),
    do: settings() |> Ecto.Changeset.change(closed: closed) |> Repo.update()

  @doc "Saves email templates, keyed by template name."
  @spec update_templates(map()) :: {:ok, Settings.t()} | {:error, Ecto.Changeset.t()}
  def update_templates(templates),
    do: settings() |> Settings.templates_changeset(templates) |> Repo.update()

  # ── Storefront images ──────────────────────────────────────────────────────

  @doc "Stores an uploaded image and returns it."
  @spec put_asset(String.t(), String.t(), binary()) ::
          {:ok, Asset.t()} | {:error, Ecto.Changeset.t()}
  def put_asset(kind, content_type, data) do
    %Asset{}
    |> Asset.changeset(%{kind: kind, content_type: content_type, data: data})
    |> Repo.insert()
  end

  @doc "An uploaded image, or nil."
  @spec get_asset(term()) :: Asset.t() | nil
  def get_asset(id), do: Repo.get(Asset, id)

  # ── Payment providers ──────────────────────────────────────────────────────

  @doc "Every payment provider, one row each, in display order."
  @spec list_providers() :: [PaymentProvider.t()]
  def list_providers do
    stored = Map.new(Repo.all(PaymentProvider), &{&1.provider, &1})

    Enum.map(PaymentProvider.providers(), fn name ->
      Map.get(stored, name) || %PaymentProvider{provider: name}
    end)
  end

  @doc "A payment provider's row, stored or new."
  @spec get_provider(String.t()) :: PaymentProvider.t()
  def get_provider(name) do
    Repo.get_by(PaymentProvider, provider: name) || %PaymentProvider{provider: name}
  end

  @doc "Saves a provider's switch, mode and credentials."
  @spec update_provider(String.t(), map()) ::
          {:ok, PaymentProvider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(name, attrs) do
    name |> get_provider() |> PaymentProvider.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc """
  Keeps a value a provider needs for itself next to its credentials, such as
  the id of a product it created on the provider's side.
  """
  @spec put_provider_data(PaymentProvider.t(), String.t(), String.t()) ::
          {:ok, PaymentProvider.t()} | {:error, Ecto.Changeset.t()}
  def put_provider_data(%PaymentProvider{} = provider, key, value) do
    provider
    |> Ecto.Changeset.change(credentials: Map.put(provider.credentials || %{}, key, value))
    |> Repo.update()
  end

  @doc """
  Tries a provider's stored keys against its API and records the result, so
  the payments page can say whether they work before a customer finds out.
  """
  @spec check_provider(String.t()) :: {:ok, PaymentProvider.t()}
  def check_provider(name) do
    provider = get_provider(name)

    result =
      if provider.id && PaymentProvider.available?(name),
        do: Payments.module(name).check_credentials(provider),
        else: {:error, "not configured"}

    error =
      case result do
        :ok -> nil
        {:error, reason} -> String.slice(reason, 0, 250)
      end

    if provider.id do
      provider
      |> Ecto.Changeset.change(checked_at: DateTime.utc_now(:second), check_error: error)
      |> Repo.update()
    else
      {:ok, %{provider | check_error: error}}
    end
  end

  @doc """
  Remembers what a provider's webhook last did - the event it delivered, or
  why it was refused - for the health line on the payments page.
  """
  @spec record_webhook(String.t(), {:ok, String.t() | nil} | {:error, String.t()}, map()) :: :ok
  def record_webhook(name, result, meta \\ %{}) do
    now = DateTime.utc_now(:second)

    {event, error} =
      case result do
        {:ok, event} -> {event, nil}
        {:error, reason} -> {meta[:event], String.slice(reason, 0, 250)}
      end

    Repo.insert!(%WebhookEvent{
      provider: name,
      event: event && String.slice(event, 0, 80),
      order_id: meta[:order_id],
      ok: error == nil,
      error: error
    })

    changes =
      case result do
        {:ok, event} ->
          [last_webhook_at: now, last_webhook_event: event && String.slice(event, 0, 80)]

        {:error, reason} ->
          [last_webhook_error_at: now, last_webhook_error: String.slice(reason, 0, 250)]
      end

    Repo.update_all(from(p in PaymentProvider, where: p.provider == ^name), set: changes)
    :ok
  end

  @test_purchase_cents 100

  @doc """
  Opens a checkout of a small amount on a provider, for an admin to try it
  end to end. The order has no customer and no package: once paid it is only
  marked paid - no VIP, no email, and it is left out of the revenue.
  """
  @spec start_test_purchase(String.t(), (Order.t() -> map())) ::
          {:ok, String.t()} | {:error, String.t()}
  def start_test_purchase(name, urls_fun) do
    if name in Enum.map(enabled_providers(), & &1.provider) do
      order =
        Repo.insert!(%Order{
          package_name: "Test purchase",
          player_id: "test",
          amount_cents: @test_purchase_cents,
          currency: settings().currency || "BRL",
          duration_days: 0,
          provider: name,
          test: true
        })

      start_checkout(order, urls_fun.(order))
    else
      {:error, "turn the payment method on first"}
    end
  end

  @doc "A provider's latest test purchase, or nil."
  @spec last_test_order(String.t()) :: Order.t() | nil
  def last_test_order(name) do
    Repo.one(
      from o in Order,
        where: o.provider == ^name and o.test,
        order_by: [desc: o.inserted_at],
        limit: 1
    )
  end

  @doc """
  The steps between installing the shop and taking a real payment, each
  with whether it is done. The shop's first page shows them until all are.
  """
  @spec setup_steps() :: [%{key: atom(), done: boolean()}]
  def setup_steps do
    settings = settings()

    [
      %{key: :package, done: Repo.exists?(from p in Package, where: p.active)},
      %{
        key: :payment,
        done: Enum.any?(enabled_providers(), &(&1.checked_at != nil and &1.check_error == nil))
      },
      %{key: :sign_in, done: settings.password_login or Settings.discord_ready?(settings)},
      %{key: :email, done: Settings.email_configured?(settings)},
      %{
        key: :test_purchase,
        done: Repo.exists?(from o in Order, where: o.test and o.status == "paid")
      }
    ]
  end

  @doc "The providers a customer can pay with."
  @spec enabled_providers() :: [PaymentProvider.t()]
  def enabled_providers do
    Enum.filter(list_providers(), &(&1.enabled and PaymentProvider.available?(&1.provider)))
  end

  # ── Packages ───────────────────────────────────────────────────────────────

  @doc "Servers that installed the shop, the ones a package may target."
  @spec shop_servers() :: [Server.t()]
  def shop_servers do
    servers = Servers.list_servers()
    installed = Features.installed_by_server(Enum.map(servers, & &1.id))
    Enum.filter(servers, &(:vip_shop in Map.get(installed, &1.id, MapSet.new())))
  end

  @doc """
  Whether the shop is open: installed on at least one server and not closed
  by an admin.
  """
  @spec open?() :: boolean()
  def open?, do: shop_servers() != [] and not settings().closed

  @doc "Every package, active or not, for the admin. Archived ones are left out."
  @spec list_packages() :: [Package.t()]
  def list_packages do
    Repo.all(
      from p in Package,
        where: is_nil(p.archived_at),
        order_by: [asc: p.position, asc: p.price_cents],
        preload: :servers
    )
  end

  @doc """
  Retires a package: off sale and out of the admin's list, while the orders
  that bought it keep pointing at it.
  """
  @spec archive_package(Package.t(), String.t() | nil) :: {:ok, Package.t()}
  def archive_package(%Package{} = package, actor \\ nil) do
    package
    |> Ecto.Changeset.change(
      archived_at: DateTime.utc_now(:second),
      active: false,
      updated_by: actor
    )
    |> Repo.update()
  end

  @doc "A copy of a package, off sale, placed after it."
  @spec duplicate_package(Package.t(), String.t() | nil) ::
          {:ok, Package.t()} | {:error, Ecto.Changeset.t()}
  def duplicate_package(%Package{} = package, actor \\ nil) do
    package = Repo.preload(package, :servers)

    save_package(
      %Package{},
      %{
        "name" => String.slice(package.name <> " (2)", 0, 80),
        "description" => package.description,
        "price" => Package.price(package),
        "compare_at" => Package.compare_at(package),
        "currency" => package.currency,
        "duration_days" => package.duration_days,
        "active" => false,
        "position" => package.position + 1,
        "server_ids" => Enum.map(package.servers, & &1.id)
      },
      actor
    )
  end

  @doc "Puts packages in the order given, as the storefront shows them."
  @spec reorder_packages([term()]) :: :ok
  def reorder_packages(ids) do
    ids
    |> Enum.map(&to_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.each(fn {id, position} ->
      Repo.update_all(from(p in Package, where: p.id == ^id), set: [position: position])
    end)
  end

  @doc "The packages on sale: active, and targeting at least one shop server."
  @spec list_active_packages() :: [Package.t()]
  def list_active_packages do
    shop_ids = MapSet.new(shop_servers(), & &1.id)

    Package
    |> where([p], p.active == true)
    |> order_by([p], asc: p.position, asc: p.price_cents)
    |> preload(:servers)
    |> Repo.all()
    |> Enum.map(fn package ->
      %{package | servers: Enum.filter(package.servers, &(&1.id in shop_ids))}
    end)
    |> Enum.reject(&(&1.servers == []))
  end

  @doc "A package with its servers."
  @spec get_package!(term()) :: Package.t()
  def get_package!(id), do: Package |> Repo.get!(id) |> Repo.preload(:servers)

  @doc "A changeset for a package form."
  @spec change_package(Package.t(), map()) :: Ecto.Changeset.t()
  def change_package(%Package{} = package, attrs \\ %{}) do
    package = Repo.preload(package, :servers)
    Package.changeset(package, attrs, package_servers(attrs, package))
  end

  @doc """
  Saves a package. `server_ids` in the attributes picks its servers; `actor`
  is who saved it, shown on the package.
  """
  @spec save_package(Package.t(), map(), String.t() | nil) ::
          {:ok, Package.t()} | {:error, Ecto.Changeset.t()}
  def save_package(%Package{} = package, attrs, actor \\ nil) do
    package
    |> change_package(attrs)
    |> then(&if(actor, do: Ecto.Changeset.put_change(&1, :updated_by, actor), else: &1))
    |> Repo.insert_or_update()
  end

  @doc "Deletes a package. Orders keep what they copied from it."
  @spec delete_package(Package.t()) :: {:ok, Package.t()} | {:error, Ecto.Changeset.t()}
  def delete_package(%Package{} = package), do: Repo.delete(package)

  # Only shop servers can be picked, whatever the form sent.
  defp package_servers(attrs, package) do
    case Map.get(attrs, "server_ids") || Map.get(attrs, :server_ids) do
      nil ->
        package.servers

      ids ->
        wanted = ids |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
        Enum.filter(shop_servers(), &(to_string(&1.id) in wanted))
    end
  end

  # ── Customers ──────────────────────────────────────────────────────────────

  @doc "A changeset for the registration form."
  @spec change_registration(map()) :: Ecto.Changeset.t()
  def change_registration(attrs \\ %{}), do: Customer.registration_changeset(%Customer{}, attrs)

  @doc "Creates an account with email and password."
  @spec register_customer(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def register_customer(attrs) do
    with {:ok, customer} <- %Customer{} |> Customer.registration_changeset(attrs) |> Repo.insert() do
      deliver_email(customer, "welcome", %{})
      {:ok, customer}
    end
  end

  @doc "The customer an email and password belong to."
  @spec authenticate_customer(String.t(), String.t()) :: {:ok, Customer.t()} | :error
  def authenticate_customer(email, password) do
    customer =
      Repo.one(
        from c in Customer,
          where: fragment("lower(?)", c.email) == ^String.downcase(String.trim(email || ""))
      )

    if Customer.valid_password?(customer, password), do: {:ok, touch(customer)}, else: :error
  end

  @doc """
  The customer a Discord account signs in as: the one already linked to it,
  or the one with the same email (which is linked from then on), or a new
  one.
  """
  @spec customer_from_discord(map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def customer_from_discord(%{"id" => discord_id} = profile) do
    attrs = %{
      discord_id: to_string(discord_id),
      discord_username: profile["username"],
      name: profile["global_name"] || profile["username"],
      email: if(profile["verified"], do: profile["email"])
    }

    existing =
      Repo.get_by(Customer, discord_id: attrs.discord_id) ||
        (attrs.email &&
           Repo.one(
             from c in Customer,
               where: fragment("lower(?)", c.email) == ^String.downcase(attrs.email)
           ))

    result =
      case existing do
        nil ->
          %Customer{} |> Customer.discord_changeset(attrs) |> Repo.insert()

        customer ->
          customer
          |> Customer.discord_changeset(Map.take(attrs, [:discord_id, :discord_username]))
          |> Repo.update()
      end

    with {:ok, customer} <- result, do: {:ok, touch(customer)}
  end

  @doc "A customer by id, or nil."
  @spec get_customer(term()) :: Customer.t() | nil
  def get_customer(nil), do: nil
  def get_customer(id), do: Repo.get(Customer, id)

  defp touch(customer) do
    customer
    |> Ecto.Changeset.change(last_login_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  # ── Password reset ─────────────────────────────────────────────────────────

  @doc """
  Emails a password reset link to the account with this email, if there is
  one. Answers the same either way, so the form never tells whether an email
  has an account. `link` builds the URL from the token.
  """
  @spec request_password_reset(String.t(), (String.t() -> String.t())) :: :ok
  def request_password_reset(email, link) when is_function(link, 1) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    case Repo.one(from c in Customer, where: fragment("lower(?)", c.email) == ^email) do
      nil ->
        :ok

      customer ->
        Repo.delete_all(
          from t in CustomerToken, where: t.customer_id == ^customer.id and t.context == "reset"
        )

        {token, row} = CustomerToken.build(customer.id, "reset")
        Repo.insert!(row)
        deliver_email(customer, "reset", %{"link" => link.(token)})
    end
  end

  @doc "The customer a valid reset token belongs to, or nil."
  @spec customer_by_reset_token(String.t()) :: Customer.t() | nil
  def customer_by_reset_token(token) when is_binary(token) do
    Repo.one(
      from t in CustomerToken.valid_query(token, "reset"),
        join: c in assoc(t, :customer),
        select: c
    )
  end

  def customer_by_reset_token(_token), do: nil

  @doc "A changeset for the new password form."
  @spec change_password(Customer.t(), map()) :: Ecto.Changeset.t()
  def change_password(%Customer{} = customer, attrs \\ %{}),
    do: Customer.password_changeset(customer, attrs)

  @doc """
  Sets a new password with a reset token, and spends every reset token of
  the account.
  """
  @spec reset_password(String.t(), map()) ::
          {:ok, Customer.t()} | {:error, Ecto.Changeset.t() | :invalid_token}
  def reset_password(token, attrs) do
    case customer_by_reset_token(token) do
      nil ->
        {:error, :invalid_token}

      customer ->
        with {:ok, customer} <- customer |> Customer.password_changeset(attrs) |> Repo.update() do
          Repo.delete_all(
            from t in CustomerToken, where: t.customer_id == ^customer.id and t.context == "reset"
          )

          {:ok, customer}
        end
    end
  end

  # ── Linked players ─────────────────────────────────────────────────────────

  @doc "The players a customer linked."
  @spec list_customer_players(Customer.t()) :: [CustomerPlayer.t()]
  def list_customer_players(%Customer{id: id}) do
    Repo.all(
      from p in CustomerPlayer, where: p.customer_id == ^id, order_by: [asc: p.player_name]
    )
  end

  @doc "Links a player to a customer. Linking the same one twice is harmless."
  @spec link_player(Customer.t(), String.t(), String.t() | nil) ::
          {:ok, CustomerPlayer.t()} | {:error, Ecto.Changeset.t()}
  def link_player(%Customer{id: id}, player_id, player_name) do
    %CustomerPlayer{customer_id: id}
    |> CustomerPlayer.changeset(%{player_id: player_id, player_name: player_name})
    |> Repo.insert(
      on_conflict: {:replace, [:player_name, :updated_at]},
      conflict_target: [:customer_id, :player_id]
    )
  end

  @doc "Removes a linked player."
  @spec unlink_player(Customer.t(), term()) :: :ok
  def unlink_player(%Customer{id: customer_id}, link_id) do
    Repo.delete_all(
      from p in CustomerPlayer, where: p.id == ^link_id and p.customer_id == ^customer_id
    )

    :ok
  end

  @doc """
  Searches the players CRCON has seen, by name, on the first shop server
  that answers: `[%{player_id, name, last_seen}]`.
  """
  @spec search_players(String.t()) :: {:ok, [map()]} | {:error, term()}
  def search_players(term) do
    term = String.trim(term || "")

    if String.length(term) < 2,
      do: {:ok, []},
      else: Enum.reduce_while(shop_servers(), {:error, :no_server}, &search_on(&1, term, &2))
  end

  defp search_on(server, term, _previous) do
    case Crcon.search_players_history(server, term) do
      {:ok, %{"players" => players}} -> {:halt, {:ok, Enum.map(players, &player_result/1)}}
      {:error, error} -> {:cont, {:error, error}}
    end
  end

  defp player_result(player) do
    name =
      case player["names"] do
        [%{"name" => name} | _rest] -> name
        [name | _rest] when is_binary(name) -> name
        _none -> player["player_id"]
      end

    %{player_id: player["player_id"], name: name, last_seen: player["last_seen_timestamp_ms"]}
  end

  # ── Orders ─────────────────────────────────────────────────────────────────

  @doc """
  Records a pending order for a package, a player and a provider.

  The player is one of the customer's linked players, or - for a gift - any
  player found in CRCON's history (`%{player_id, player_name, gift: true}`).

  ## Options

    * `:coupon` - a coupon code to apply
  """
  @spec create_order(Customer.t(), Package.t(), CustomerPlayer.t() | map(), String.t(), keyword()) ::
          {:ok, Order.t()} | {:error, term()}
  def create_order(%Customer{} = customer, %Package{} = package, player, provider, opts \\ []) do
    with :ok <- check_player(customer, player),
         :ok <-
           if(provider in Enum.map(enabled_providers(), & &1.provider),
             do: :ok,
             else: {:error, :provider_disabled}
           ),
         :ok <- if(package.active, do: :ok, else: {:error, :package_inactive}),
         {:ok, coupon, discount} <- apply_coupon(Keyword.get(opts, :coupon), package, customer) do
      insert_order(customer, package, player, provider, coupon, discount)
    end
  end

  defp check_player(customer, %CustomerPlayer{customer_id: id}),
    do: if(id == customer.id, do: :ok, else: {:error, :not_your_player})

  defp check_player(_customer, %{player_id: id, gift: true}) when is_binary(id) and id != "",
    do: :ok

  defp check_player(_customer, _player), do: {:error, :not_your_player}

  defp insert_order(customer, package, player, provider, coupon, discount) do
    %Order{
      customer_id: customer && customer.id,
      package_id: package.id,
      package_name: package.name,
      player_id: player.player_id,
      player_name: player.player_name,
      amount_cents: package.price_cents - discount,
      discount_cents: discount,
      coupon_id: coupon && coupon.id,
      coupon_code: coupon && coupon.code,
      gift: Map.get(player, :gift, false),
      currency: package.currency,
      duration_days: package.duration_days,
      provider: provider
    }
    |> Repo.insert()
  end

  @doc """
  Checks a coupon code against a package: `{:ok, coupon, discount_cents}`,
  `{:ok, nil, 0}` for no code, or `{:error, :invalid_coupon}`.
  """
  @spec apply_coupon(String.t() | nil, Package.t(), Customer.t() | nil) ::
          {:ok, Coupon.t() | nil, non_neg_integer()} | {:error, :invalid_coupon}
  def apply_coupon(code, %Package{} = package, customer \\ nil) do
    code = code |> to_string() |> String.trim() |> String.upcase()

    if code == "" do
      {:ok, nil, 0}
    else
      from(c in Coupon, where: fragment("upper(?)", c.code) == ^code)
      |> Repo.one()
      |> coupon_discount(package, customer)
    end
  end

  defp coupon_discount(%Coupon{} = coupon, package, customer) do
    if Coupon.usable?(coupon) and Coupon.covers?(coupon, package.id) and
         not used_by?(coupon, customer),
       do: {:ok, coupon, Coupon.discount(coupon, package.price_cents)},
       else: {:error, :invalid_coupon}
  end

  defp coupon_discount(nil, _package, _customer), do: {:error, :invalid_coupon}

  # "Once per customer": a paid order of theirs with the coupon spends it.
  defp used_by?(%Coupon{once_per_customer: true, id: id}, %Customer{id: customer_id}) do
    Repo.exists?(
      from o in Order,
        where:
          o.coupon_id == ^id and o.customer_id == ^customer_id and
            o.status in ~w(paid fulfilled partial failed)
    )
  end

  defp used_by?(_coupon, _customer), do: false

  # ── Coupons ────────────────────────────────────────────────────────────────

  @doc "Every coupon, newest first."
  @spec list_coupons() :: [Coupon.t()]
  def list_coupons, do: Repo.all(from c in Coupon, order_by: [desc: c.inserted_at])

  @doc "A coupon by id."
  @spec get_coupon!(term()) :: Coupon.t()
  def get_coupon!(id), do: Repo.get!(Coupon, id)

  @doc "A changeset for a coupon form."
  @spec change_coupon(Coupon.t(), map()) :: Ecto.Changeset.t()
  def change_coupon(%Coupon{} = coupon, attrs \\ %{}), do: Coupon.changeset(coupon, attrs)

  @doc "Creates or updates a coupon. `actor` is kept as its creator on a new one."
  @spec save_coupon(Coupon.t(), map(), String.t() | nil) ::
          {:ok, Coupon.t()} | {:error, Ecto.Changeset.t()}
  def save_coupon(%Coupon{} = coupon, attrs, actor \\ nil) do
    coupon
    |> Coupon.changeset(attrs)
    |> then(
      &if(is_nil(coupon.id) and actor,
        do: Ecto.Changeset.put_change(&1, :created_by, actor),
        else: &1
      )
    )
    |> Repo.insert_or_update()
  end

  @doc "Switches a coupon on or off."
  @spec toggle_coupon(Coupon.t()) :: {:ok, Coupon.t()}
  def toggle_coupon(%Coupon{} = coupon),
    do: coupon |> Ecto.Changeset.change(active: not coupon.active) |> Repo.update()

  @doc "Deletes a coupon. Orders keep the code they used."
  @spec delete_coupon(Coupon.t()) :: {:ok, Coupon.t()} | {:error, Ecto.Changeset.t()}
  def delete_coupon(%Coupon{} = coupon), do: Repo.delete(coupon)

  # ── Manual grants ──────────────────────────────────────────────────────────

  @doc """
  Grants a package to a player from the admin, free: prizes, courtesies,
  fixing a purchase made elsewhere. Recorded as a paid order of zero with
  who gave it, and fulfilled like any other.
  """
  @spec grant_manually(Package.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, Order.t()} | {:error, term()}
  def grant_manually(%Package{} = package, player_id, player_name, admin_name) do
    player_id = String.trim(player_id || "")

    if player_id == "" do
      {:error, :no_player}
    else
      {:ok, order} =
        %Order{
          package_id: package.id,
          package_name: package.name,
          player_id: player_id,
          player_name: player_name,
          amount_cents: 0,
          currency: package.currency,
          duration_days: package.duration_days,
          provider: "manual",
          granted_by: admin_name
        }
        |> Repo.insert()

      mark_paid(order)
    end
  end

  @doc """
  Grants VIP by hand for some days on some servers, without a package:
  prizes, courtesies. `attrs` carries `:player_id`, `:player_name`,
  `:duration_days` (nil for permanent), `:server_ids`, `:reason` and
  `:admin`. Recorded as a paid order of zero and fulfilled like any other.
  """
  @spec grant_vip(map()) :: {:ok, Order.t()} | {:error, :no_player | :no_server}
  def grant_vip(attrs) do
    player_id = String.trim(attrs[:player_id] || "")
    shop_ids = MapSet.new(shop_servers(), & &1.id)

    server_ids =
      (attrs[:server_ids] || [])
      |> Enum.map(&to_integer/1)
      |> Enum.filter(&MapSet.member?(shop_ids, &1))

    cond do
      player_id == "" ->
        {:error, :no_player}

      server_ids == [] ->
        {:error, :no_server}

      true ->
        days = attrs[:duration_days]

        {:ok, order} =
          %Order{
            package_name: manual_package_name(days),
            player_id: player_id,
            player_name: attrs[:player_name],
            amount_cents: 0,
            currency: settings().currency || "BRL",
            duration_days: days,
            provider: "manual",
            granted_by: attrs[:admin],
            reason: blank_to_nil(attrs[:reason]),
            server_ids: server_ids
          }
          |> Repo.insert()

        mark_paid(order)
    end
  end

  # A manual grant takes the name of the package with the same days, when
  # there is one, so the purchases list reads the same.
  defp manual_package_name(days) do
    query =
      if days,
        do: from(p in Package, where: p.duration_days == ^days),
        else: from(p in Package, where: is_nil(p.duration_days))

    Repo.one(
      from p in query,
        where: is_nil(p.archived_at),
        order_by: [asc: p.position],
        limit: 1,
        select: p.name
    ) || "VIP"
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(_value), do: nil

  @doc """
  Marks a paid order refunded - the money was returned at the provider - and
  removes the VIP it granted from every server that took it.
  """
  @spec refund_order(Order.t(), String.t() | nil) :: {:ok, Order.t()} | {:error, :not_paid}
  def refund_order(%Order{} = order, actor) do
    order = Repo.preload(order, :grants, force: true)

    if order.status in ~w(paid fulfilled partial failed) and not order.test do
      servers = Map.new(Servers.list_servers(), &{&1.id, &1})

      Enum.each(order.grants, &remove_granted_vip(&1, servers, order.player_id))

      Repo.update_all(
        from(g in Grant, where: g.order_id == ^order.id and g.status == "granted"),
        set: [status: "removed", updated_at: DateTime.utc_now(:second)]
      )

      {:ok, order} =
        order
        |> Ecto.Changeset.change(
          status: "refunded",
          refunded_at: DateTime.utc_now(:second),
          refunded_by: actor
        )
        |> Repo.update()

      {:ok, broadcast(get_order(order.id))}
    else
      {:error, :not_paid}
    end
  end

  defp remove_granted_vip(grant, servers, player_id) do
    with "granted" <- grant.status,
         %Server{} = server <- servers[grant.server_id] do
      Crcon.remove_vip(server, player_id)
    end
  end

  @doc "Sends an order's receipt again."
  @spec resend_receipt(Order.t()) :: :ok
  def resend_receipt(%Order{} = order) do
    order = get_order(order.id)
    deliver_email(order.customer, "purchase", receipt(order))
    mark_receipt_sent(order)
    :ok
  end

  defp mark_receipt_sent(%Order{customer: %Customer{email: email}} = order)
       when is_binary(email) do
    Repo.update_all(from(o in Order, where: o.id == ^order.id),
      set: [receipt_sent_at: DateTime.utc_now(:second)]
    )
  end

  defp mark_receipt_sent(_order), do: :ok

  @doc """
  Opens the provider's checkout for a pending order and returns the page to
  send the customer to. `urls` carries `:success`, `:cancel`, `:webhook` and
  optionally the customer's `:email`.
  """
  @spec start_checkout(Order.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def start_checkout(%Order{} = order, urls) do
    provider = get_provider(order.provider)

    with {:ok, %{url: url, ref: ref}} <-
           Payments.module(order.provider).checkout(provider, order, urls),
         {:ok, _order} <- put_provider_ref(order, ref) do
      {:ok, url}
    else
      {:error, %Ecto.Changeset{}} -> {:error, "could not record the checkout"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies what a provider reported: marks the order paid or canceled.
  Unknown orders and anything else are ignored.
  """
  @spec apply_outcome(String.t(), Payments.outcome()) :: {:ok, Order.t() | nil}
  def apply_outcome(provider, {:paid, ref}) do
    case find_order(provider, ref) do
      nil -> {:ok, nil}
      order -> mark_paid(order)
    end
  end

  def apply_outcome(provider, {:canceled, ref, reason}) do
    case find_order(provider, ref) do
      nil -> {:ok, nil}
      order -> cancel_order(order, reason)
    end
  end

  def apply_outcome(_provider, :ignore), do: {:ok, nil}

  defp find_order(provider, {:provider_ref, ref}), do: get_order_by_ref(provider, ref)

  defp find_order(provider, {:order_id, id}) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(Order, id: id, provider: provider)
      _other -> nil
    end
  end

  @doc "Stores the id the provider gave the checkout."
  @spec put_provider_ref(Order.t(), String.t()) :: {:ok, Order.t()} | {:error, Ecto.Changeset.t()}
  def put_provider_ref(%Order{} = order, ref) do
    order |> Ecto.Changeset.change(provider_ref: ref) |> Repo.update()
  end

  @doc "An order with its grants."
  @spec get_order(term()) :: Order.t() | nil
  def get_order(id), do: Order |> Repo.get(id) |> Repo.preload([:grants, :customer])

  @doc "The order a provider reference belongs to."
  @spec get_order_by_ref(String.t(), String.t()) :: Order.t() | nil
  def get_order_by_ref(provider, ref),
    do: Repo.get_by(Order, provider: provider, provider_ref: ref)

  @doc """
  Marks an order paid and queues its VIP. Safe to call more than once - the
  provider's webhook and the customer's return page may both report it.
  """
  @spec mark_paid(Order.t()) :: {:ok, Order.t()} | {:error, term()}
  def mark_paid(%Order{status: "pending"} = order) do
    {count, _rows} =
      Repo.update_all(
        from(o in Order, where: o.id == ^order.id and o.status == "pending"),
        set: [
          status: "paid",
          paid_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        ]
      )

    if count == 1 and not order.test do
      if order.coupon_id,
        do: Repo.update_all(from(c in Coupon, where: c.id == ^order.coupon_id), inc: [uses: 1])

      %{order_id: order.id}
      |> HllConditionalActions.Workers.FulfillVipOrder.new()
      |> Oban.insert()
    end

    order = get_order(order.id)
    {:ok, broadcast(order)}
  end

  def mark_paid(%Order{} = order), do: {:ok, order}

  @doc "Marks a pending order canceled: refused, expired or refunded."
  @spec cancel_order(Order.t(), String.t() | nil) :: {:ok, Order.t()}
  def cancel_order(%Order{status: "pending"} = order, reason) do
    {:ok, order} =
      order |> Ecto.Changeset.change(status: "canceled", error: reason) |> Repo.update()

    {:ok, broadcast(order)}
  end

  def cancel_order(%Order{} = order, _reason), do: {:ok, order}

  @doc "The latest orders, newest first, for the purchases page."
  @spec recent_orders(keyword()) :: [Order.t()]
  def recent_orders(opts \\ []) do
    Order
    |> maybe_status(Keyword.get(opts, :status))
    |> order_by([o], desc: o.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> preload([:customer, :grants])
    |> Repo.all()
  end

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, ""), do: query
  defp maybe_status(query, status), do: where(query, [o], o.status == ^status)

  @doc "A customer's orders, newest first."
  @spec customer_orders(Customer.t()) :: [Order.t()]
  def customer_orders(%Customer{id: id}) do
    Repo.all(
      from o in Order,
        where: o.customer_id == ^id,
        order_by: [desc: o.inserted_at],
        preload: :grants
    )
  end

  @doc "Totals for the purchases page: paid orders and revenue per currency."
  @spec totals() :: %{orders: non_neg_integer(), revenue: [{String.t(), integer()}]}
  def totals do
    paid = ~w(paid fulfilled partial failed)

    revenue =
      Repo.all(
        from o in Order,
          where: o.status in ^paid and not o.test,
          group_by: o.currency,
          select: {o.currency, sum(o.amount_cents)}
      )

    %{
      orders: Repo.aggregate(from(o in Order, where: o.status in ^paid and not o.test), :count),
      revenue: revenue
    }
  end

  # ── Fulfilment ─────────────────────────────────────────────────────────────

  @doc """
  Grants a paid order's VIP on every server of its package, and records how
  each went. With the shop set to extend, the days are added to what the
  player has left on that server.
  """
  @spec fulfill(Order.t()) :: {:ok, Order.t()}
  def fulfill(%Order{test: true} = order), do: {:ok, order}

  def fulfill(%Order{} = order) do
    order = Repo.preload(order, [:grants, package: :servers], force: true)
    servers = order_servers(order)
    first_attempt? = order.grants == []
    stacking = settings().stacking

    # A server that already took the VIP on an earlier attempt is not asked
    # again.
    grants =
      Enum.map(servers, fn server ->
        Enum.find(order.grants, &(&1.server_id == server.id and &1.status == "granted")) ||
          grant_on(order, server, stacking)
      end)

    status = fulfilment_status(grants)

    {:ok, order} =
      order
      |> Ecto.Changeset.change(
        status: status,
        fulfilled_at: if(status == "fulfilled", do: DateTime.utc_now(:second)),
        error: if(servers == [], do: "the package has no server left")
      )
      |> Repo.update()

    order = get_order(order.id)
    notify_fulfilment(order, status, first_attempt?)

    {:ok, broadcast(order)}
  end

  defp notify_fulfilment(order, status, first_attempt?) do
    if status in ["fulfilled", "partial"] and is_nil(order.receipt_sent_at) do
      deliver_email(order.customer, "purchase", receipt(order))
      mark_receipt_sent(order)
    end

    # The customer hears about a server that did not take the VIP once, on
    # the first attempt, when the shop switched that email on.
    if status in ["partial", "failed"] and first_attempt? and
         Emails.enabled?(settings(), "delivery_failed"),
       do: deliver_email(order.customer, "delivery_failed", receipt(order))

    if status in ["partial", "failed"], do: alert_failure(order)
  end

  # A manual grant names its servers; a purchase takes its package's.
  defp order_servers(%Order{server_ids: [_ | _] = ids}) do
    Repo.all(from s in Server, where: s.id in ^ids, order_by: [asc: s.id])
  end

  defp order_servers(%Order{package: %Package{servers: servers}}), do: servers
  defp order_servers(_order), do: []

  # A paid VIP that did not reach every server needs a human: it shows in the
  # Attention inbox, and in Discord when an alert webhook is set.
  defp alert_failure(order) do
    HllConditionalActions.Attention.notify_changed()

    case settings().alert_webhook_id do
      nil ->
        :ok

      webhook_id ->
        failed =
          order.grants
          |> Enum.filter(&(&1.status == "failed"))
          |> Enum.map_join(", ", & &1.server_name)

        content =
          "VIP Shop: order ##{order.id} (#{order.package_name}) for #{order.player_name || order.player_id} " <>
            "was paid but the VIP failed on: #{failed}. Retry it from the purchases page."

        HllConditionalActions.Workers.DeliverWebhook.enqueue(webhook_id, %{
          "content" => content,
          "allowed_mentions" => %{"parse" => []}
        })
    end
  end

  @doc "Paid orders whose VIP did not reach every server, for the Attention inbox."
  @spec failed_orders() :: [Order.t()]
  def failed_orders do
    Repo.all(
      from o in Order,
        where: o.status in ["partial", "failed"],
        order_by: [desc: o.updated_at],
        limit: 50,
        preload: :grants
    )
  end

  defp fulfilment_status(grants) do
    case Enum.frequencies_by(grants, & &1.status) do
      %{"granted" => _n} = counts when map_size(counts) == 1 -> "fulfilled"
      %{"granted" => _n} -> "partial"
      _none -> "failed"
    end
  end

  defp grant_on(order, server, stacking) do
    expires_at = expiration(order, server, stacking)
    description = "VIP Shop ##{order.id} - #{order.package_name}"

    {status, error} =
      case Crcon.add_vip(server, order.player_id, description, expires_at) do
        {:ok, _result} -> {"granted", nil}
        {:error, error} -> {"failed", Exception.message(error)}
      end

    %Grant{
      order_id: order.id,
      server_id: server.id,
      server_name: server.name,
      status: status,
      expires_at: expires_at,
      error: error
    }
    |> Repo.insert!(on_conflict: :nothing)
  end

  @doc """
  When a VIP bought now should end on a server: `nil` for permanent, the
  package's days from now, or - extending - from the current expiry when it
  is still in the future.
  """
  @spec expiration(Order.t(), Server.t(), String.t()) :: DateTime.t() | nil
  def expiration(%Order{duration_days: nil}, _server, _stacking), do: nil

  def expiration(%Order{duration_days: days} = order, server, stacking) do
    now = DateTime.utc_now(:second)
    base = if stacking == "extend", do: current_expiry(server, order.player_id, now), else: now
    base && DateTime.add(base, days * 86_400, :second)
  end

  @doc """
  The VIP a player has now on the shop's servers, read from CRCON: the
  latest expiry among them, `:permanent`, or nil when none has them as VIP.
  """
  @spec current_vip(String.t()) :: DateTime.t() | :permanent | nil
  def current_vip(player_id) do
    now = DateTime.utc_now(:second)

    shop_servers()
    |> Enum.map(&server_vip(&1, player_id, now))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      found -> if :permanent in found, do: :permanent, else: Enum.max(found, DateTime)
    end
  end

  defp server_vip(server, player_id, now) do
    with {:ok, vips} when is_list(vips) <- Crcon.get_vip_ids(server),
         %{"vip_expiration" => at} <- Enum.find(vips, &(&1["player_id"] == player_id)) do
      vip_expiry(at, now)
    else
      _none -> nil
    end
  end

  defp vip_expiry(at, now) do
    case DateTime.from_iso8601(normalize_iso(at)) do
      {:ok, %DateTime{year: year}, _offset} when year >= 2999 -> :permanent
      {:ok, expiry, _offset} -> if DateTime.after?(expiry, now), do: expiry
      _other -> if is_nil(at), do: :permanent
    end
  end

  # Permanent VIP stays permanent (nil); an expired one starts from now.
  defp current_expiry(server, player_id, now) do
    with {:ok, vips} when is_list(vips) <- Crcon.get_vip_ids(server),
         %{"vip_expiration" => at} <- Enum.find(vips, &(&1["player_id"] == player_id)),
         {:ok, expiry, _offset} <- DateTime.from_iso8601(normalize_iso(at)) do
      cond do
        expiry.year >= 2999 -> nil
        DateTime.compare(expiry, now) == :gt -> DateTime.truncate(expiry, :second)
        true -> now
      end
    else
      _none -> now
    end
  end

  defp normalize_iso(at) when is_binary(at) do
    if String.match?(at, ~r/(Z|[+-]\d{2}:?\d{2})$/), do: at, else: at <> "Z"
  end

  defp normalize_iso(_at), do: ""

  @doc "The placeholders of an order's receipt email."
  @spec receipt(Order.t()) :: map()
  def receipt(order) do
    granted = Enum.filter(order.grants, &(&1.status == "granted"))

    %{
      "order_id" => to_string(order.id),
      "package" => order.package_name,
      "player" => order.player_name || order.player_id,
      "amount" => format_money(order.amount_cents, order.currency),
      "servers" => Enum.map_join(granted, ", ", & &1.server_name),
      "expires_at" =>
        case granted |> Enum.map(& &1.expires_at) |> Enum.reject(&is_nil/1) do
          [] -> ""
          dates -> dates |> Enum.max(DateTime) |> Calendar.strftime("%d/%m/%Y")
        end,
      "shop_url" => HllConditionalActionsWeb.Endpoint.url() <> "/shop/orders/#{order.id}",
      "duration" =>
        if(order.duration_days,
          do:
            Gettext.dngettext(
              HllConditionalActionsWeb.Gettext,
              "default",
              "%{count} day",
              "%{count} days",
              order.duration_days
            ),
          else: ""
        ),
      "provider" => provider_label(order.provider),
      "player_id" => order.player_id
    }
  end

  defp provider_label("mercado_pago"), do: "Mercado Pago"
  defp provider_label("stripe"), do: "Stripe"
  defp provider_label("dodo"), do: "Dodo Payments"
  defp provider_label(_other), do: ""

  @doc """
  An amount in cents, written the way its currency is usually written.

      iex> HllConditionalActions.VipShop.format_money(1990, "BRL")
      "R$ 19,90"
      iex> HllConditionalActions.VipShop.format_money(123456, "USD")
      "$1,234.56"
      iex> HllConditionalActions.VipShop.format_money(500, "CHF")
      "CHF 5.00"
  """
  @spec format_money(integer(), String.t()) :: String.t()
  def format_money(cents, currency) do
    {symbol, separator, decimal} =
      case currency do
        "BRL" -> {"R$ ", ".", ","}
        "EUR" -> {"€ ", ".", ","}
        "ARS" -> {"$ ", ".", ","}
        "USD" -> {"$", ",", "."}
        "GBP" -> {"£", ",", "."}
        other -> {other <> " ", ",", "."}
      end

    units =
      cents
      |> div(100)
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(separator, &Enum.join/1)
      |> String.reverse()

    symbol <> units <> decimal <> String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
  end

  # ── Expiry reminders ───────────────────────────────────────────────────────

  @doc """
  Emails customers whose VIP ends within the configured number of days, once
  per grant, with a link back to the shop. `link` is the shop's URL.
  Returns how many were sent.
  """
  @spec send_expiry_reminders(String.t()) :: non_neg_integer()
  def send_expiry_reminders(link) do
    days = settings().reminder_days

    if days in [nil, 0] or
         not Emails.enabled?(settings(), "expiring") do
      0
    else
      now = DateTime.utc_now(:second)
      until = DateTime.add(now, days * 86_400, :second)

      grants =
        Repo.all(
          from g in Grant,
            join: o in assoc(g, :order),
            where:
              g.status == "granted" and is_nil(g.reminded_at) and not is_nil(g.expires_at) and
                g.expires_at > ^now and g.expires_at <= ^until and not is_nil(o.customer_id),
            preload: [order: :customer]
        )

      grants
      |> Enum.group_by(& &1.order_id)
      |> Enum.each(fn {_order_id, [first | _rest] = grants} ->
        order = first.order

        deliver_email(order.customer, "expiring", %{
          "package" => order.package_name,
          "player" => order.player_name || order.player_id,
          "servers" => Enum.map_join(grants, ", ", & &1.server_name),
          "date" => Calendar.strftime(first.expires_at, "%d/%m/%Y"),
          "link" => link
        })

        ids = Enum.map(grants, & &1.id)
        Repo.update_all(from(g in Grant, where: g.id in ^ids), set: [reminded_at: now])
      end)

      length(grants)
    end
  end

  # ── Email ──────────────────────────────────────────────────────────────────

  defp deliver_email(nil, _template, _vars), do: :ok
  defp deliver_email(%Customer{email: nil}, _template, _vars), do: :ok

  defp deliver_email(%Customer{} = customer, template, vars) do
    if wants?(customer, template), do: queue_email(customer, template, vars), else: :ok
  end

  # Receipts and expiry reminders follow the customer's email preferences;
  # the welcome and the password reset always go.
  defp wants?(customer, template) when template in ["purchase", "delivery_failed"],
    do: Storefront.wants_email?(customer.id, :receipts)

  defp wants?(customer, "expiring"),
    do: Storefront.wants_email?(customer.id, :expiry_reminders)

  defp wants?(_customer, _template), do: true

  defp queue_email(customer, template, vars) do
    vars =
      Map.merge(%{"name" => customer.name || "", "shop" => settings().shop_title || ""}, vars)

    %{to: customer.email, template: template, vars: vars}
    |> HllConditionalActions.Workers.SendShopEmail.new()
    |> Oban.insert()

    :ok
  end
end
