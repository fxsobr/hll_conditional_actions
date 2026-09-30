defmodule HllConditionalActionsWeb.VipShopLive.Settings do
  @moduledoc """
  The Loja VIP's setup and settings, one page per tab:

    * **setup** - the guide that opens the shop (`SetupGuide`)
    * **design** - the storefront, edited as a draft and published
      (`StorefrontPanel`); `/vip-shop/settings` opens it with the shop's
      names and texts
    * **payments** - the payment methods and their health (`PaymentsPanel`)
    * **login** and **general** - how customers sign in and the purchase
      rules (`RulesPanel`)
    * **email** - the sending service and the templates (`EmailPanel`)

  Secrets are never sent back to the browser: leaving one blank keeps what is
  stored.
  """

  use HllConditionalActionsWeb, :live_view

  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}
  on_mount HllConditionalActionsWeb.VipShopLive.Tabs

  import HllConditionalActionsWeb.VipShopLive.Tabs
  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop

  alias HllConditionalActions.VipShop.{
    Asset,
    AssetInfo,
    Customer,
    Design,
    Emails,
    LiveServers,
    PaymentProvider
  }

  alias HllConditionalActions.VipShop.{Settings, Stats}
  alias HllConditionalActions.Workers.SendShopEmail
  alias HllConditionalActionsWeb.Endpoint
  alias HllConditionalActionsWeb.ShopComponents

  alias HllConditionalActionsWeb.VipShopLive.{
    EmailPanel,
    PaymentsPanel,
    RulesPanel,
    SetupGuide,
    StorefrontPanel
  }

  import Ecto.Query, only: [from: 2]

  @sections %{
    "setup" => :setup,
    "design" => :design,
    "payments" => :payments,
    "login" => :login,
    "email" => :email,
    "general" => :general
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: VipShop.subscribe()

    {:ok,
     socket
     |> assign(:page_title, gettext("VIP shop settings"))
     |> assign(:pick, "dodo")
     |> assign(:preview_mode, "desktop")
     |> assign(:template, "purchase")
     |> assign(:sample, nil)
     |> allow_upload(:logo,
       accept: Asset.extensions(),
       max_entries: 1,
       max_file_size: Asset.max_bytes(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> allow_upload(:banner,
       accept: Asset.extensions(),
       max_entries: 1,
       max_file_size: Asset.max_bytes(),
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> allow_upload(:auth_image,
       accept: Asset.extensions(),
       max_entries: 1,
       max_file_size: Asset.max_bytes(),
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    section =
      case socket.assigns.live_action do
        :page -> :design
        :section -> Map.get(@sections, params["section"], :design)
      end

    socket =
      socket
      |> assign(:section, section)
      |> assign(:more_open, socket.assigns.live_action == :page)
      |> assign(:editing, editing(section, params))
      |> load()

    {:noreply, socket}
  end

  # The payments page opens the provider asked for, or the first one that
  # still needs something.
  defp editing(:payments, %{"provider" => provider}) do
    if provider in PaymentProvider.providers(), do: provider
  end

  defp editing(:payments, _params) do
    providers = VipShop.list_providers()

    case Enum.find(
           providers,
           &(&1.enabled and (&1.check_error != nil or &1.last_webhook_at == nil))
         ) ||
           Enum.find(providers, & &1.enabled) do
      nil -> nil
      provider -> provider.provider
    end
  end

  defp editing(_section, _params), do: nil

  defp load(socket) do
    settings = VipShop.settings()

    socket
    |> assign(:settings, settings)
    |> assign(:vip_nav, nav())
    |> assign(:providers, VipShop.list_providers())
    |> load_section(socket.assigns.section, settings)
  end

  defp load_section(socket, :setup, settings) do
    guide = SetupGuide.load(settings)

    pick =
      case guide.enabled do
        [first | _rest] -> first.provider
        [] -> socket.assigns.pick
      end

    socket |> assign(:guide, guide) |> assign(:pick, pick)
  end

  defp load_section(socket, :design, settings) do
    draft = VipShop.design_draft(settings)
    servers = VipShop.shop_servers()

    socket
    |> assign(:draft, with_lists(draft))
    |> assign(:published, VipShop.design_draft(%{settings | design_draft: nil}) |> with_lists())
    |> assign(:changes, VipShop.unpublished_changes(settings))
    |> assign(:page_form, section_form(:page, settings))
    |> assign(:assets, %{
      logo: AssetInfo.get(draft["logo_asset_id"]),
      banner: AssetInfo.get(draft["banner_asset_id"])
    })
    |> assign(:shop_packages, VipShop.list_active_packages())
    |> assign(:servers, servers)
    |> assign(:live, live_servers(servers))
    |> fetch_live(servers)
  end

  defp load_section(socket, :payments, _settings) do
    socket
    |> assign(:payments, PaymentsPanel.load())
    |> assign(
      :test_orders,
      Map.new(PaymentProvider.providers(), &{&1, VipShop.last_test_order(&1)})
    )
    |> assign_provider_form()
  end

  defp load_section(socket, :email, settings) do
    samples = EmailPanel.sample_orders()
    sample = socket.assigns.sample || List.first(samples)

    socket
    |> assign(:form, section_form(:email, settings))
    |> assign(:samples, samples)
    |> assign(:sample, sample)
    |> assign(:counts, Stats.email_counts(30))
    |> assign(:last_test, Stats.last_email_to(socket.assigns.current_user.email))
    |> assign_template_form()
  end

  defp load_section(socket, :login, settings) do
    socket
    |> assign(:form, section_form(:login, settings))
    |> assign(:customers, %{
      password: Repo.aggregate(from(c in Customer, where: not is_nil(c.hashed_password)), :count),
      discord: Repo.aggregate(from(c in Customer, where: not is_nil(c.discord_id)), :count)
    })
  end

  defp load_section(socket, :general, settings) do
    socket
    |> assign(:form, section_form(:general, settings))
    |> assign(:expiring_week, Stats.expiring_vips(DateTime.utc_now(:second), 7))
    |> assign(:example, RulesPanel.extension_example())
    |> assign(:webhooks, HllConditionalActions.Discord.list_webhooks())
  end

  # The preview's player counts: what is cached at once, then a fresh read
  # in the background (the same read the public page makes).
  defp fetch_live(socket, servers) do
    if connected?(socket) and servers != [] do
      start_async(socket, :live, fn ->
        LiveServers.fetch(servers)
      end)
    else
      socket
    end
  end

  @impl Phoenix.LiveView
  def handle_async(:live, {:ok, live}, socket) when is_map(live),
    do: {:noreply, assign(socket, :live, live)}

  def handle_async(:live, _result, socket), do: {:noreply, socket}

  # Servers read live for the storefront preview; a failure only hides the
  # player counts.
  defp live_servers(servers) do
    LiveServers.cached(servers)
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
  end

  # The design as the editor shows it: the translated examples stand in for
  # benefits and questions until the admin writes their own.
  defp with_lists(design) do
    defaults = ShopComponents.default_design_lists()

    %{
      design
      | "benefits" => design["benefits"] || defaults["benefits"],
        "faq" => design["faq"] || defaults["faq"]
    }
  end

  defp section_form(section, settings) do
    settings |> blank_secrets() |> then(&change_form(section, &1)) |> to_form(as: :settings)
  end

  defp change_form(:page, s), do: Settings.page_changeset(s, %{})
  defp change_form(:login, s), do: Settings.login_changeset(s, %{})
  defp change_form(:email, s), do: Settings.email_changeset(s, %{})
  defp change_form(:general, s), do: Settings.general_changeset(s, %{})

  defp blank_secrets(settings),
    do: %{settings | discord_client_secret: nil, smtp_password: nil, email_api_key: nil}

  defp assign_provider_form(socket) do
    case socket.assigns.editing do
      nil ->
        assign(socket, :provider_form, nil)

      name ->
        record = VipShop.get_provider(name)

        assign(
          socket,
          :provider_form,
          to_form(%{"enabled" => record.enabled, "mode" => record.mode, "credentials" => %{}},
            as: :provider
          )
        )
    end
  end

  defp assign_template_form(socket) do
    %{subject: subject, body: body} =
      Emails.template(socket.assigns.settings, socket.assigns.template)

    socket
    |> assign(:template_form, to_form(%{"subject" => subject, "body" => body}, as: :template))
    |> assign(:template_draft, %{subject: subject, body: body})
  end

  defp actor(socket), do: socket.assigns.current_user.name || socket.assigns.current_user.username

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_info({:vip_order, %{test: true}}, socket), do: {:noreply, load(socket)}
  def handle_info({:vip_order, _order}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("validate", %{"settings" => params}, socket) do
    section = if socket.assigns.section == :design, do: :page, else: socket.assigns.section

    changeset =
      section
      |> VipShop.change_settings(params)
      |> Map.update!(:data, &blank_secrets/1)
      |> Map.put(:action, :validate)

    key = if section == :page, do: :page_form, else: :form
    {:noreply, assign(socket, key, to_form(changeset, as: :settings))}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"settings" => params} = all, socket) do
    section = if socket.assigns.section == :design, do: :page, else: socket.assigns.section

    with :ok <- save_expiring_flag(section, all),
         {:ok, _settings} <- VipShop.update_settings(section, params) do
      {:noreply, socket |> put_flash(:info, gettext("Settings saved.")) |> load()}
    else
      {:error, changeset} ->
        changeset = Map.update!(changeset, :data, &blank_secrets/1)
        key = if section == :page, do: :page_form, else: :form
        {:noreply, assign(socket, key, to_form(changeset, as: :settings))}
    end
  end

  def handle_event("reminder-days", %{"delta" => delta}, socket) do
    form = socket.assigns.form
    current = form[:reminder_days].value

    days =
      case Integer.parse(to_string(current || "0")) do
        {n, _rest} -> n
        :error -> 0
      end

    days = (days + String.to_integer(delta)) |> max(0) |> min(30)
    params = form.params |> Map.put("reminder_days", to_string(days))

    changeset =
      :general
      |> VipShop.change_settings(params)
      |> Map.update!(:data, &blank_secrets/1)

    {:noreply, assign(socket, :form, to_form(changeset, as: :settings))}
  end

  def handle_event("open-shop", _params, socket) do
    {:ok, _settings} = VipShop.set_closed(false)
    {:noreply, socket |> put_flash(:info, gettext("The shop is open to the public.")) |> load()}
  end

  def handle_event("close-shop", _params, socket) do
    {:ok, _settings} = VipShop.set_closed(true)
    {:noreply, socket |> put_flash(:info, gettext("The shop is closed.")) |> load()}
  end

  def handle_event("setup-pick", %{"provider" => provider}, socket) do
    if provider in PaymentProvider.providers(),
      do: {:noreply, assign(socket, :pick, provider)},
      else: {:noreply, socket}
  end

  # ── Payments ──

  def handle_event("check-provider", %{"provider" => name}, socket) do
    {:ok, checked} = VipShop.check_provider(name)
    {:noreply, socket |> flash_check(checked, nil) |> load()}
  end

  def handle_event("set-state", %{"provider" => name, "state" => state}, socket) do
    record = VipShop.get_provider(name)

    attrs =
      case state do
        "off" -> %{"enabled" => false}
        "on" -> %{"enabled" => true}
        "test" -> %{"enabled" => true, "mode" => "test"}
        "live" -> %{"enabled" => true, "mode" => "live"}
      end

    case VipShop.update_provider(name, attrs) do
      {:ok, _record} ->
        socket =
          if attrs["enabled"] and Map.get(attrs, "mode", record.mode) != record.mode do
            {:ok, checked} = VipShop.check_provider(name)
            flash_check(socket, checked, gettext("Mode changed."))
          else
            put_flash(socket, :info, gettext("Payment method saved."))
          end

        {:noreply, load(socket)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}
    end
  end

  def handle_event("test-purchase", %{"provider" => name}, socket) do
    email = socket.assigns.current_user.email

    urls = fn order ->
      %{
        success: Endpoint.url() <> ~p"/shop/return/#{name}?order=#{order.id}&test=1",
        cancel: Endpoint.url() <> ~p"/vip-shop/settings/payments",
        webhook: Endpoint.url() <> ~p"/webhooks/#{name}",
        email: email
      }
    end

    case VipShop.start_test_purchase(name, urls) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The test purchase could not start: %{reason}", reason: reason)
         )}
    end
  end

  def handle_event("save-provider", %{"provider" => params}, socket) do
    name = socket.assigns.editing

    case VipShop.update_provider(name, params) do
      {:ok, _record} ->
        # Saving is when a typo in a key is cheapest to catch.
        {:ok, checked} = VipShop.check_provider(name)
        {:noreply, socket |> flash_check(checked, gettext("Payment method saved.")) |> load()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}
    end
  end

  # ── Design ──

  def handle_event("design-change", %{"design" => params}, socket) do
    draft = socket.assigns.draft
    params = with_accent(params, draft)
    design = params |> Design.from_params(draft) |> merge_lists(params) |> keep_images(draft)
    {:ok, settings} = VipShop.save_design_draft(stored_draft(design))

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:draft, design)
     |> assign(:changes, VipShop.unpublished_changes(settings))}
  end

  def handle_event("design-change", _params, socket), do: {:noreply, socket}

  def handle_event("design-save", params, socket) do
    socket =
      case params do
        %{"design" => design} ->
          elem(handle_event("design-change", %{"design" => design}, socket), 1)

        _none ->
          socket
      end

    {:ok, _settings} = VipShop.publish_design()

    {:noreply, socket |> put_flash(:info, gettext("Storefront published.")) |> load()}
  end

  def handle_event("design-reorder", %{"ids" => ids}, socket) do
    draft = socket.assigns.draft
    by_key = Map.new(draft["sections"], &{&1["key"], &1})
    sections = ids |> Enum.map(&by_key[&1]) |> Enum.reject(&is_nil/1)
    draft = %{draft | "sections" => sections ++ (draft["sections"] -- sections)}
    {:noreply, save_draft(socket, draft)}
  end

  def handle_event("accent-pick", %{"color" => color}, socket) do
    draft = socket.assigns.draft
    theme_accent = Design.theme(draft["theme"]).accent

    accent =
      if String.downcase(color) == String.downcase(theme_accent),
        do: nil,
        else: String.downcase(color)

    {:noreply, save_draft(socket, %{draft | "accent" => accent})}
  end

  def handle_event("remove-draft-image", %{"field" => field}, socket)
      when field in ~w(logo_asset_id banner_asset_id) do
    {:noreply,
     socket |> save_draft(Map.put(socket.assigns.draft, field, nil)) |> refresh_assets()}
  end

  def handle_event("preview-mode", %{"mode" => mode}, socket) when mode in ~w(desktop phone),
    do: {:noreply, assign(socket, :preview_mode, mode)}

  def handle_event("design-add", %{"list" => list}, socket) when list in ~w(benefits faq) do
    row =
      if list == "benefits",
        do: %{"icon" => "star", "title" => "", "text" => ""},
        else: %{"q" => "", "a" => ""}

    {:noreply, update(socket, :draft, &Map.update!(&1, list, fn rows -> rows ++ [row] end))}
  end

  def handle_event("design-remove", %{"list" => list, "index" => index}, socket)
      when list in ~w(benefits faq) do
    index = String.to_integer(index)
    draft = Map.update!(socket.assigns.draft, list, &List.delete_at(&1, index))
    {:noreply, save_draft(socket, draft)}
  end

  def handle_event("cancel-upload", %{"upload" => upload, "ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  # ── E-mail ──

  def handle_event("pick-template", %{"template" => name}, socket) do
    if name in Emails.names() do
      {:noreply, socket |> assign(:template, name) |> assign_template_form()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("sample-order", %{"order" => id}, socket) do
    sample = Enum.find(socket.assigns.samples, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :sample, sample)}
  end

  def handle_event(
        "save-template",
        %{"template" => %{"subject" => subject, "body" => body}},
        socket
      ) do
    stored = Map.get(socket.assigns.settings.email_templates || %{}, socket.assigns.template, %{})

    {:ok, _settings} =
      VipShop.update_templates(%{
        socket.assigns.template =>
          Map.merge(stored, %{
            "subject" => subject,
            "body" => body,
            "updated_by" => actor(socket),
            "updated_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          })
      })

    {:noreply, socket |> put_flash(:info, gettext("Template saved.")) |> load()}
  end

  def handle_event(
        "preview-template",
        %{"template" => %{"subject" => subject, "body" => body}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:template_draft, %{subject: subject, body: body})
     |> assign(:template_form, to_form(%{"subject" => subject, "body" => body}, as: :template))}
  end

  def handle_event("reset-template", _params, socket) do
    stored = Map.get(socket.assigns.settings.email_templates || %{}, socket.assigns.template, %{})
    kept = Map.take(stored, ["enabled"])
    {:ok, _settings} = VipShop.update_templates(%{socket.assigns.template => kept})
    {:noreply, socket |> put_flash(:info, gettext("Template restored to the default.")) |> load()}
  end

  def handle_event("toggle-template", %{"template" => name}, socket)
      when name in ["expiring", "delivery_failed"] do
    settings = socket.assigns.settings
    stored = Map.get(settings.email_templates || %{}, name, %{})

    {:ok, _settings} =
      VipShop.update_templates(%{
        name => Map.put(stored, "enabled", not Emails.enabled?(settings, name))
      })

    {:noreply, load(socket)}
  end

  def handle_event("test-email", %{"to" => to}, socket) do
    settings = VipShop.settings()
    draft = socket.assigns.template_draft

    # The draft on screen, saved or not, is what gets sent.
    result =
      if Settings.email_configured?(settings) do
        started = System.monotonic_time(:millisecond)

        result =
          settings
          |> Emails.build_text(draft.subject, draft.body, to, sample_vars(socket.assigns))
          |> SendShopEmail.deliver(settings)

        Stats.log_email(
          socket.assigns.template,
          to,
          result,
          System.monotonic_time(:millisecond) - started
        )

        result
      else
        {:error, :not_configured}
      end

    socket = load(socket)

    case result do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Test email sent to %{to}.", to: to))}

      {:error, :not_configured} ->
        {:noreply,
         put_flash(socket, :error, gettext("Configure and save the email service first."))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Sending failed: %{reason}", reason: inspect(reason)))}
    end
  end

  # ── Helpers ──

  defp save_expiring_flag(:general, %{"expiring_email" => value}) do
    settings = VipShop.settings()
    stored = Map.get(settings.email_templates || %{}, "expiring", %{})

    {:ok, _settings} =
      VipShop.update_templates(%{"expiring" => Map.put(stored, "enabled", value == "true")})

    :ok
  end

  defp save_expiring_flag(_section, _params), do: :ok

  defp save_draft(socket, draft) do
    {:ok, settings} = VipShop.save_design_draft(stored_draft(draft))

    socket
    |> assign(:settings, settings)
    |> assign(:draft, draft)
    |> assign(:changes, VipShop.unpublished_changes(settings))
  end

  # The examples shown in the editor are not stored until the admin edits
  # them: a list equal to the translated defaults stays nil.
  defp stored_draft(draft) do
    defaults = ShopComponents.default_design_lists()

    Enum.reduce(~w(benefits faq), draft, fn list, acc ->
      if acc[list] == defaults[list], do: Map.put(acc, list, nil), else: acc
    end)
  end

  # A typed colour counts as the admin's own unless it is the theme's.
  defp with_accent(params, draft) do
    typed = params["accent"] |> to_string() |> String.trim() |> String.downcase()
    theme = params["theme"] || draft["theme"]
    theme_accent = Design.theme(theme).accent
    old_theme_accent = Design.theme(draft["theme"]).accent

    custom =
      typed =~ ~r/^#[0-9a-f]{6}$/ and typed != theme_accent and
        (draft["accent"] != nil or typed != old_theme_accent)

    params |> Map.put("accent", typed) |> Map.put("custom_accent", to_string(custom))
  end

  # While typing, keep blank rows the admin just added: from_params drops
  # them, which is right when publishing but would delete them from the form.
  defp merge_lists(design, params) do
    Enum.reduce(~w(benefits faq), design, fn list, acc ->
      rows =
        params
        |> Map.get(list, %{})
        |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
        |> Enum.map(&elem(&1, 1))

      if rows == [], do: acc, else: Map.put(acc, list, rows)
    end)
  end

  defp keep_images(design, draft) do
    Map.merge(design, Map.take(draft, ~w(logo_asset_id banner_asset_id)))
  end

  defp refresh_assets(socket) do
    draft = socket.assigns.draft

    assign(socket, :assets, %{
      logo: AssetInfo.get(draft["logo_asset_id"]),
      banner: AssetInfo.get(draft["banner_asset_id"])
    })
  end

  # An image goes into the draft as soon as it is uploaded.
  defp handle_progress(upload, entry, socket) when upload in [:logo, :banner, :auth_image] do
    if entry.done? do
      id =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, asset} = VipShop.put_asset(to_string(upload), entry.client_type, File.read!(path))
          {:ok, asset.id}
        end)

      draft = socket.assigns.draft

      draft =
        case upload do
          :logo -> Map.put(draft, "logo_asset_id", id)
          :banner -> Map.put(draft, "banner_asset_id", id)
          :auth_image -> put_in(draft, ["auth", "image_id"], id)
        end

      {:noreply, socket |> save_draft(draft) |> refresh_assets()}
    else
      {:noreply, socket}
    end
  end

  defp flash_check(socket, %PaymentProvider{check_error: nil} = provider, prefix) do
    message =
      gettext("%{provider} accepted the keys.", provider: provider_name(provider.provider))

    put_flash(socket, :info, Enum.join(Enum.reject([prefix, message], &is_nil/1), " "))
  end

  defp flash_check(socket, %PaymentProvider{} = provider, _prefix) do
    put_flash(
      socket,
      :error,
      gettext("%{provider} refused the keys: %{reason}",
        provider: provider_name(provider.provider),
        reason: provider.check_error
      )
    )
  end

  defp changeset_message(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, error} ->
      "#{field} #{translate_error(error)}"
    end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Community")}
      greeting={section_title(@section)}
      greeting_eyebrow={gettext("Community · VIP shop")}
      scope={false}
    >
      <:actions>
        <%= case @section do %>
          <% :setup -> %>
            <span class={[
              "hidden h-8 items-center gap-2 rounded-full px-3 text-xs font-semibold sm:flex",
              if(VipShop.open?(), do: "vip-chip-ok", else: "vip-chip-warn")
            ]}>
              <span class="vip-dot"></span>
              {if VipShop.open?(), do: gettext("Shop open"), else: gettext("Shop closed")}
            </span>
            <.link navigate={~p"/vip-shop?guide=skip"} id="skip-guide" class="vip-btn">
              {gettext("Skip the guide")}
            </.link>
          <% :design -> %>
            <span
              :if={@changes > 0}
              id="unpublished"
              class="hidden items-center gap-2 text-[0.8125rem] vip-warn sm:flex"
            >
              <span class="vip-dot"></span>
              {ngettext("%{count} unpublished change", "%{count} unpublished changes", @changes)}
            </span>
            <span
              :if={@changes == 0}
              class="hidden items-center gap-2 text-[0.8125rem] text-muted sm:flex"
            >
              <span class="vip-dot vip-dot-ok"></span>{gettext("Everything published")}
            </span>
            <button
              type="submit"
              form="design-form"
              id="publish-storefront"
              class="vip-btn vip-btn-cta"
            >
              {gettext("Publish storefront")}
            </button>
          <% section when section in [:login, :general] -> %>
            <.open_shop_link />
            <button
              type="submit"
              form={if section == :login, do: "login-form", else: "general-form"}
              id="save-settings"
              class="vip-btn vip-btn-cta"
            >
              {gettext("Save changes")}
            </button>
          <% _other -> %>
            <.open_shop_link class="!inline-flex" />
        <% end %>
      </:actions>

      <.tabs current={@section} nav={@vip_nav} />

      <SetupGuide.guide :if={@section == :setup} data={@guide} pick={@pick} />

      <StorefrontPanel.storefront
        :if={@section == :design}
        draft={@draft}
        published={@published}
        settings={@settings}
        page_form={@page_form}
        uploads={@uploads}
        assets={@assets}
        packages={@shop_packages}
        servers={@servers}
        live={@live}
        preview_mode={@preview_mode}
        more_open={@more_open}
      />

      <PaymentsPanel.payments
        :if={@section == :payments}
        providers={@providers}
        editing={@editing}
        provider_form={@provider_form}
        test_orders={@test_orders}
        data={@payments}
      />

      <EmailPanel.email
        :if={@section == :email}
        settings={@settings}
        form={@form}
        template={@template}
        template_form={@template_form}
        draft={@template_draft}
        samples={@samples}
        sample={@sample}
        vars={sample_vars(assigns)}
        current_user={@current_user}
        last_test={@last_test}
        counts={@counts}
      />

      <RulesPanel.layout
        :if={@section in [:login, :general]}
        section={@section}
        settings={@settings}
        providers={@providers}
        open={VipShop.open?()}
      >
        <RulesPanel.login
          :if={@section == :login}
          form={@form}
          settings={@settings}
          customers={@customers}
        />
        <RulesPanel.general
          :if={@section == :general}
          form={@form}
          settings={@settings}
          expiring_week={@expiring_week}
          example={@example}
          webhooks={@webhooks}
        />
      </RulesPanel.layout>
    </Layouts.app>
    """
  end

  defp sample_vars(%{settings: settings, current_user: user} = assigns),
    do: EmailPanel.sample_vars(settings, user, assigns[:sample])

  defp section_title(:setup), do: gettext("Open the shop")
  defp section_title(:design), do: gettext("Storefront")
  defp section_title(:payments), do: gettext("Payments")
  defp section_title(:login), do: gettext("Customer sign in")
  defp section_title(:email), do: gettext("E-mail")
  defp section_title(:general), do: gettext("Purchase rules")
end
