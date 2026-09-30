defmodule HllConditionalActionsWeb.VipShopLive.EmailPanel do
  @moduledoc """
  The shop's e-mail (VipEmails board): the sending service with a test and
  what went out in 30 days; the templates, the suggested ones included; and
  the template being edited, with its placeholders and a live preview filled
  with a real order. Rendered by `HllConditionalActionsWeb.VipShopLive.Settings`.
  """

  use HllConditionalActionsWeb, :html

  import HllConditionalActionsWeb.VipShopLive.Components

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Design, Emails, Settings}

  @doc "Recent paid orders the preview can be filled with."
  @spec sample_orders() :: list()
  def sample_orders do
    VipShop.recent_orders(status: "fulfilled", limit: 8) |> Enum.reject(& &1.test)
  end

  @doc """
  The placeholders the preview and the test e-mail fill: a real order's
  receipt when there is one, a sample otherwise.
  """
  @spec sample_vars(Settings.t(), map(), map() | nil) :: map()
  def sample_vars(settings, user, order) do
    base = %{
      "name" => user.name || "Admin",
      "shop" => settings.shop_title || "VIP shop",
      "order_id" => "1042",
      "package" => "VIP 30",
      "player" => "Player",
      "player_id" => "76561198000000000",
      "amount" => VipShop.format_money(1990, settings.currency || "BRL"),
      "servers" => "#1, #2",
      "duration" => ngettext("%{count} day", "%{count} days", 30),
      "provider" => "Mercado Pago",
      "expires_at" => Date.utc_today() |> Date.add(30) |> Calendar.strftime("%d/%m/%Y"),
      "shop_url" => HllConditionalActionsWeb.Endpoint.url() <> "/shop",
      "date" => Date.utc_today() |> Date.add(30) |> Calendar.strftime("%d/%m/%Y"),
      "link" => HllConditionalActionsWeb.Endpoint.url() <> "/shop"
    }

    case order do
      nil ->
        base

      order ->
        customer = order.customer
        name = (customer && (customer.name || customer.email)) || base["name"]
        Map.merge(base, VipShop.receipt(order)) |> Map.put("name", name)
    end
  end

  attr :settings, :map, required: true
  attr :form, :any, required: true
  attr :template, :string, required: true
  attr :template_form, :any, required: true
  attr :draft, :map, required: true
  attr :samples, :list, required: true
  attr :sample, :any, default: nil
  attr :vars, :map, required: true
  attr :current_user, :map, required: true
  attr :last_test, :any, default: nil
  attr :counts, :map, required: true

  def email(assigns) do
    saved = Emails.template(assigns.settings, assigns.template)

    assigns =
      assigns
      |> assign(
        :changes,
        Enum.count([:subject, :body], &(Map.get(saved, &1) != Map.get(assigns.draft, &1)))
      )
      |> assign(:stored, Map.get(assigns.settings.email_templates || %{}, assigns.template, %{}))

    ~H"""
    <div class="grid gap-5 lg:grid-cols-[16.375rem_18.75rem] xl:grid-cols-[16.375rem_18.75rem_minmax(0,1fr)]">
      <.service
        settings={@settings}
        form={@form}
        last_test={@last_test}
        counts={@counts}
        current_user={@current_user}
      />
      <.templates settings={@settings} template={@template} />
      <.editor
        settings={@settings}
        template={@template}
        template_form={@template_form}
        draft={@draft}
        samples={@samples}
        sample={@sample}
        vars={@vars}
        changes={@changes}
        stored={@stored}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :settings, :map, required: true
  attr :form, :any, required: true
  attr :last_test, :any, default: nil
  attr :counts, :map, required: true
  attr :current_user, :map, required: true

  defp service(assigns) do
    assigns = assign(assigns, :provider, assigns.form[:email_provider].value || "smtp")

    ~H"""
    <.vip_panel label={gettext("Sending service")} class="flex flex-col gap-3.5 p-[1.375rem]">
      <h2 class="font-display text-xl font-semibold">{gettext("Sending service")}</h2>
      <.form
        for={@form}
        id="email-form"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-3.5"
      >
        <div
          role="radiogroup"
          aria-label={gettext("Sending service")}
          class="vip-seg border border-line-raised"
        >
          <label
            :for={{value, label} <- [{"smtp", "SMTP"}, {"sendgrid", "SendGrid"}, {"brevo", "Brevo"}]}
            class="!h-8 !px-2"
          >
            <input
              type="radio"
              name="settings[email_provider]"
              value={value}
              checked={@provider == value}
            />
            {label}
          </label>
        </div>

        <%= if @provider in ["sendgrid", "brevo"] do %>
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("API key")}</span>
            <input
              type="password"
              name="settings[email_api_key]"
              id="settings_email_api_key"
              value=""
              autocomplete="off"
              placeholder={mask(@settings.email_api_key) || "SG.…"}
              class="vip-field !h-[2.625rem] font-mono !text-xs"
            />
          </label>
        <% else %>
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Server")}</span>
            <input
              type="text"
              name="settings[smtp_host]"
              id="settings_smtp_host"
              value={@form[:smtp_host].value}
              placeholder="smtp.example.com"
              class="vip-field !h-[2.625rem] font-mono !text-[0.8125rem]"
            />
          </label>
          <div class="grid grid-cols-[5rem_minmax(0,1fr)] gap-2">
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Port")}</span>
              <input
                type="number"
                name="settings[smtp_port]"
                value={@form[:smtp_port].value}
                placeholder="587"
                class="vip-field !h-[2.625rem] font-mono"
              />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-[0.8125rem] text-subtle">{gettext("Encryption")}</span>
              <select name="settings[smtp_tls]" class="vip-field !h-[2.625rem]">
                <option
                  :for={mode <- Settings.tls_modes()}
                  value={mode}
                  selected={@form[:smtp_tls].value == mode}
                >
                  {Labels.smtp_tls(mode)}
                </option>
              </select>
            </label>
          </div>
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Username")}</span>
            <input
              type="text"
              name="settings[smtp_username]"
              value={@form[:smtp_username].value}
              autocomplete="off"
              class="vip-field !h-[2.625rem]"
            />
          </label>
          <label class="flex flex-col gap-1.5">
            <span class="text-[0.8125rem] text-subtle">{gettext("Password")}</span>
            <input
              type="password"
              name="settings[smtp_password]"
              value=""
              autocomplete="off"
              placeholder={if @settings.smtp_password, do: "••••••••", else: ""}
              class="vip-field !h-[2.625rem]"
            />
          </label>
        <% end %>

        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Sender name")}</span>
          <input
            type="text"
            name="settings[mail_from_name]"
            value={@form[:mail_from_name].value}
            class="vip-field !h-[2.625rem]"
          />
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Sender address")}</span>
          <input
            type="email"
            name="settings[mail_from_address]"
            value={@form[:mail_from_address].value}
            class="vip-field !h-[2.625rem] font-mono !text-[0.8125rem]"
          />
          <span
            :for={error <- Keyword.get_values(@form.errors, :mail_from_address)}
            :if={@form.source.action}
            class="text-xs vip-err"
          >
            {translate_error(error)}
          </span>
        </label>
        <button
          type="submit"
          id="save-email-service"
          class="vip-btn vip-btn-raised !h-10 text-[0.8125rem]"
        >
          {gettext("Save service")}
        </button>
      </.form>

      <div class="vip-ok-box flex flex-col gap-2.5 rounded-[1.125rem] p-3.5">
        <button
          type="button"
          id="test-send"
          phx-click="test-email"
          phx-value-to={@current_user.email}
          phx-disable-with={gettext("Sending...")}
          class="vip-btn vip-btn-raised !h-10 text-[0.8125rem]"
        >
          {gettext("Test sending")}
        </button>
        <span :if={@last_test} class="flex items-start gap-2 text-xs leading-[1.45] text-subtle">
          <.icon
            name={if @last_test.ok, do: "hero-check", else: "hero-x-mark"}
            class={["mt-px size-3.5 shrink-0", if(@last_test.ok, do: "vip-ok", else: "vip-err")]}
          />
          <span>
            <%= if @last_test.ok do %>
              <strong class="font-semibold vip-ok">
                {gettext("Delivered in %{seconds} s", seconds: seconds(@last_test.duration_ms))}
              </strong>
            <% else %>
              <strong class="font-semibold vip-err">{gettext("Failed")}</strong> · {@last_test.error}
            <% end %>
            <br />{gettext("to %{address}", address: @last_test.to)} ·
            <.vip_time id="last-test-at" at={@last_test.inserted_at} />
          </span>
        </span>
      </div>

      <span class="flex-1"></span>
      <div class="flex flex-col gap-1.5 border-t border-line-soft pt-3">
        <span class="flex justify-between text-[0.8125rem]">
          <span class="text-subtle">{gettext("Sent in 30 days")}</span>
          <span class="font-mono">{@counts.sent}</span>
        </span>
        <span class="flex justify-between text-[0.8125rem]">
          <span class="text-subtle">{gettext("Failed")}</span>
          <span class={["font-mono", @counts.failed > 0 && "vip-err"]}>{@counts.failed}</span>
        </span>
        <span class="mt-1 text-xs leading-[1.45] text-muted">
          <%= if Settings.email_configured?(@settings) do %>
            {gettext("Receipts go out through this service, with a plain text copy.")}
          <% else %>
            {gettext("Without a service on, the receipt shows only on the order page.")}
          <% end %>
        </span>
      </div>
    </.vip_panel>
    """
  end

  attr :settings, :map, required: true
  attr :template, :string, required: true

  defp templates(assigns) do
    ~H"""
    <.vip_panel
      id="email-templates"
      label={gettext("Templates")}
      class="flex flex-col gap-1.5 px-3.5 py-[1.375rem]"
    >
      <div class="flex items-baseline px-2 pb-2">
        <h2 class="flex-1 font-display text-xl font-semibold">{gettext("Templates")}</h2>
        <span class="text-xs text-muted">{length(Emails.names())}</span>
      </div>

      <.template_item
        :for={name <- Emails.names() -- Emails.optional()}
        name={name}
        settings={@settings}
        current={@template}
      />

      <div class="mx-2 my-1.5 h-px bg-line-soft"></div>
      <span class="px-2 pb-0.5 pt-1 text-xs uppercase tracking-[0.06em] text-muted">
        {gettext("Suggested")}
      </span>

      <.template_item
        :for={name <- Emails.optional()}
        name={name}
        settings={@settings}
        current={@template}
        suggested
      />

      <span class="flex-1"></span>
      <span class="px-2 pt-3 text-xs leading-normal text-muted">
        {gettext("All go out in HTML with the logo and the accent colour of the")}
        <.link navigate={~p"/vip-shop/settings/design"} class="text-primary">{gettext("Storefront")}</.link>, {gettext(
          "with a plain text version along."
        )}
      </span>
    </.vip_panel>
    """
  end

  attr :name, :string, required: true
  attr :settings, :map, required: true
  attr :current, :string, required: true
  attr :suggested, :boolean, default: false

  defp template_item(assigns) do
    assigns =
      assigns
      |> assign(:custom, Emails.custom?(assigns.settings, assigns.name))
      |> assign(:enabled, Emails.enabled?(assigns.settings, assigns.name))

    ~H"""
    <button
      type="button"
      id={"template-#{@name}"}
      phx-click="pick-template"
      phx-value-template={@name}
      aria-current={@name == @current && "true"}
      class={[
        "flex flex-col gap-1 rounded-2xl px-3.5 py-3 text-left transition-colors",
        cond do
          @name == @current -> "border border-line-strong bg-secondary"
          @suggested -> "border border-dashed border-line-raised hover:bg-secondary/60"
          true -> "border border-transparent hover:bg-secondary/60"
        end
      ]}
    >
      <span class="flex items-center gap-2">
        <span class={[
          "flex-1 text-sm",
          if(@name == @current, do: "font-semibold", else: "font-medium")
        ]}>
          {template_name(@name)}
        </span>
        <%= cond do %>
          <% @suggested and @enabled -> %>
            <.vip_chip tone="ok" class="px-2 py-[0.1875rem]">{gettext("on")}</.vip_chip>
          <% @suggested -> %>
            <.vip_chip tone="eng" class="px-2 py-[0.1875rem]">{gettext("new")}</.vip_chip>
          <% @custom -> %>
            <.vip_chip tone="ok" class="px-2 py-[0.1875rem]">{gettext("custom")}</.vip_chip>
          <% true -> %>
            <.vip_chip class="px-2 py-[0.1875rem]">{gettext("default")}</.vip_chip>
        <% end %>
      </span>
      <span class={["text-xs", if(@name == @current, do: "text-subtle", else: "text-muted")]}>
        {template_when(@name, @settings)}<span :if={@suggested}> · {if @enabled,
          do: gettext("on"),
          else: gettext("off")}</span>
      </span>
    </button>
    """
  end

  attr :settings, :map, required: true
  attr :template, :string, required: true
  attr :template_form, :any, required: true
  attr :draft, :map, required: true
  attr :samples, :list, required: true
  attr :sample, :any, default: nil
  attr :vars, :map, required: true
  attr :changes, :integer, required: true
  attr :stored, :map, required: true
  attr :current_user, :map, required: true

  defp editor(assigns) do
    ~H"""
    <.vip_panel
      id="template-editor"
      label={template_name(@template)}
      class="flex min-w-0 flex-col gap-3 px-[1.375rem] py-5 lg:col-span-2 xl:col-span-1"
    >
      <div class="flex flex-wrap items-center gap-3">
        <span class="flex min-w-0 flex-1 flex-col gap-0.5">
          <h2 class="font-display text-xl font-semibold">{template_name(@template)}</h2>
          <span class="text-xs text-muted">
            <%= if @stored["updated_at"] do %>
              {@stored["updated_by"] || "?"} ·
              <.vip_time
                id="template-updated"
                at={parse_time(@stored["updated_at"])}
                format="datetime"
              />
            <% else %>
              {gettext("Default text")}
            <% end %>
            <span :if={@changes > 0} class="vip-warn">
              · {ngettext("%{count} change", "%{count} changes", @changes)}
            </span>
          </span>
        </span>
        <label
          :if={@template in Emails.optional()}
          class="flex items-center gap-2 text-[0.8125rem] text-subtle"
        >
          {gettext("Send it")}
          <.vip_switch
            name="enabled"
            id="template-enabled"
            checked={Emails.enabled?(@settings, @template)}
            label={gettext("Send this e-mail")}
            phx-click="toggle-template"
            phx-value-template={@template}
          />
        </label>
        <button
          type="button"
          id="reset-template"
          phx-click="reset-template"
          class="h-10 px-3.5 text-[0.8125rem] text-subtle hover:text-base-content"
        >
          {gettext("Restore default")}
        </button>
        <button type="submit" form="template-form" id="save-template" class="vip-btn vip-btn-cta">
          {gettext("Save template")}
        </button>
      </div>

      <.form
        for={@template_form}
        id="template-form"
        phx-change="preview-template"
        phx-submit="save-template"
        phx-hook=".VipInsert"
        class="flex flex-col gap-3"
      >
        <label class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Subject")}</span>
          <input
            type="text"
            name="template[subject]"
            id="template_subject"
            value={@template_form[:subject].value}
            class="vip-field !h-[2.625rem]"
          />
        </label>

        <div class="flex flex-col gap-1.5">
          <span class="text-[0.8125rem] text-subtle">{gettext("Body")}</span>
          <div class="overflow-hidden rounded-xl border border-line-raised bg-secondary">
            <div
              role="toolbar"
              aria-label={gettext("Formatting")}
              class="flex flex-wrap items-center gap-0.5 border-b border-base-300 px-1.5 py-1"
            >
              <button
                type="button"
                data-wrap="**"
                aria-label={gettext("Bold")}
                class="h-7 w-[1.875rem] rounded-lg text-[0.8125rem] font-bold text-subtle hover:bg-base-100"
              >B</button>
              <button
                type="button"
                data-link
                aria-label={gettext("Insert link")}
                class="flex h-7 w-[1.875rem] items-center justify-center rounded-lg text-subtle hover:bg-base-100"
              >
                <.icon name="hero-link" class="size-3.5" />
              </button>
              <button
                type="button"
                data-insert={"\n" <> gettext("[button: Follow the delivery → {shop_url}]") <> "\n"}
                class="h-7 rounded-lg px-2.5 text-xs text-subtle hover:bg-base-100"
              >
                {gettext("Button")}
              </button>
              <button
                type="button"
                data-insert={"\n" <> gettext("[order summary]") <> "\n"}
                class="h-7 rounded-lg px-2.5 text-xs text-subtle hover:bg-base-100"
              >
                {gettext("Order summary")}
              </button>
              <span class="flex-1"></span>
              <span class="pr-1.5 text-[0.6875rem] text-muted">{gettext("HTML + plain text")}</span>
            </div>
            <textarea
              name="template[body]"
              id="template_body"
              rows="6"
              aria-label={gettext("E-mail body")}
              class="block min-h-[8.5rem] w-full resize-y border-0 [field-sizing:content] bg-transparent px-3.5 py-2.5 text-[0.8125rem] leading-[1.55] outline-0 focus:ring-0"
            >{@template_form[:body].value}</textarea>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-1.5">
          <span class="mr-0.5 text-xs text-muted">{gettext("Insert")}</span>
          <button
            :for={placeholder <- Emails.placeholders(@template)}
            type="button"
            data-insert={"{#{placeholder}}"}
            class="vip-token !h-[1.625rem] !px-[0.5625rem] !text-[0.6875rem]"
          >
            {"{#{placeholder}}"}
          </button>
        </div>
      </.form>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".VipInsert">
        export default {
          mounted() {
            this.target = this.el.querySelector("textarea")
            this.el.addEventListener("focusin", (e) => {
              if (e.target.matches("input[type=text], textarea")) this.target = e.target
            })
            const put = (field, text, select) => {
              const start = field.selectionStart ?? field.value.length
              const end = field.selectionEnd ?? start
              field.setRangeText(text, start, end, select ? "select" : "end")
              field.focus()
              field.dispatchEvent(new Event("input", {bubbles: true}))
            }
            this.el.addEventListener("click", (e) => {
              const button = e.target.closest("button[data-insert], button[data-wrap], button[data-link]")
              if (!button) return
              const field = this.target
              const selected = field.value.slice(field.selectionStart, field.selectionEnd)
              if (button.dataset.insert) put(field, button.dataset.insert)
              else if (button.dataset.wrap) put(field, `${button.dataset.wrap}${selected || "…"}${button.dataset.wrap}`)
              else put(field, `[${selected || "…"}](https://)`)
            })
          }
        }
      </script>

      <div class="flex min-h-0 flex-1 flex-col gap-2.5 border-t border-line-soft pt-3">
        <div class="flex flex-wrap items-center gap-2.5">
          <.dot_label class="text-[0.8125rem] font-semibold !text-base-content">
            {gettext("Live preview")}
          </.dot_label>
          <form id="sample-order" phx-change="sample-order">
            <label class="relative flex h-[1.875rem] items-center gap-1.5 rounded-full border border-line-raised bg-secondary pl-2.5 pr-7 text-xs text-subtle">
              {gettext("Sample order:")}
              <select
                name="order"
                class="cursor-pointer appearance-none border-0 bg-transparent p-0 text-xs text-base-content focus:ring-0"
              >
                <option value="">{gettext("sample")}</option>
                <option
                  :for={order <- @samples}
                  value={order.id}
                  selected={@sample && @sample.id == order.id}
                >
                  #{order.id} {order.player_name || order.player_id}
                </option>
              </select>
              <.icon name="hero-chevron-down" class="pointer-events-none absolute right-2.5 size-3.5" />
            </label>
          </form>
          <span class="flex-1"></span>
          <button
            type="button"
            id="send-template-to-me"
            phx-click="test-email"
            phx-value-to={@current_user.email}
            class="vip-btn vip-btn-raised vip-btn-md !h-9 !border-base-300"
          >
            <.icon name="hero-paper-airplane" class="size-4" />{gettext("Send this template to me")}
          </button>
        </div>

        <.preview settings={@settings} draft={@draft} vars={@vars} />
      </div>
    </.vip_panel>
    """
  end

  attr :settings, :map, required: true
  attr :draft, :map, required: true
  attr :vars, :map, required: true

  defp preview(assigns) do
    design = Design.get(assigns.settings.design)
    accent = design["accent"] || Design.theme(design["theme"]).accent

    assigns =
      assigns
      |> assign(:blocks, Emails.blocks(assigns.draft.body, assigns.vars))
      |> assign(:accent, accent)
      |> assign(:on_accent, Design.on_color(accent))

    ~H"""
    <div
      id="template-preview"
      class="vip-mail flex min-h-[20rem] flex-1 flex-col overflow-hidden rounded-[1.125rem]"
    >
      <div class="flex flex-col gap-0.5 border-b border-[#e2e1d8] bg-[#fbfaf6] px-4 py-[0.5625rem] text-xs text-[#4f5148]">
        <span>
          <span class="text-[#6b6d64]">{gettext("From (sender)")}</span>
          {@settings.mail_from_name || @settings.shop_title || "VIP Shop"} &lt;{@settings.mail_from_address ||
            "…"}&gt; <span class="text-[#6b6d64]">· {gettext("to")}</span> {preview_to(@vars)}
        </span>
        <span class="font-semibold text-[#16170f]">{Emails.render(@draft.subject, @vars)}</span>
      </div>
      <div class="flex flex-1 justify-center overflow-hidden px-3 pt-2.5">
        <div class="vip-mail-card flex w-full max-w-[29.375rem] flex-col overflow-hidden rounded-t-[0.875rem]">
          <div class="flex h-[3.125rem] shrink-0 items-center gap-2.5 bg-[#14160f] px-[1.125rem]">
            <span class="flex size-[1.875rem] items-center justify-center overflow-hidden rounded-[0.5625rem] border border-[#2e3029] bg-[#20211d] text-[#f3f2ec]">
              <img
                :if={@settings.logo_asset_id}
                src={~p"/shop/assets/#{@settings.logo_asset_id}"}
                alt=""
                class="size-full object-cover"
              />
              <.icon :if={!@settings.logo_asset_id} name="hero-shield-check" class="size-4" />
            </span>
            <strong class="font-display text-[0.9375rem] font-bold text-[#f3f2ec]">
              {@settings.shop_title || "VIP Shop"}
            </strong>
            <span class="text-xs text-[#b3b4ab]">{gettext("VIP shop")}</span>
            <span class="flex-1"></span>
            <span class="h-1 w-11 rounded-sm" style={"background: #{@accent}"}></span>
          </div>
          <div class="flex flex-col gap-2 px-[1.375rem] pb-4 pt-3.5">
            <%= for block <- @blocks do %>
              <%= case block do %>
                <% {:paragraph, lines} -> %>
                  <p class="text-[0.8125rem] leading-[1.55] text-[#4f5148]">
                    <%= for {line, index} <- Enum.with_index(lines) do %>
                      <br :if={index > 0} /><.segments segments={line} />
                    <% end %>
                  </p>
                <% {:summary} -> %>
                  <div class="flex flex-col rounded-xl bg-[#f2f1eb] px-3.5 py-1">
                    <span
                      :for={{{label, value}, index} <- Enum.with_index(Emails.summary_rows(@vars))}
                      class={[
                        "flex justify-between gap-3 py-1.5 text-xs",
                        index < 2 && "border-b border-[#e2e1d8]"
                      ]}
                    >
                      <span class="text-[#6b6d64]">{label}</span><span class="text-right">{value}</span>
                    </span>
                  </div>
                <% {:button, label, _url} -> %>
                  <span
                    class="flex h-[2.375rem] items-center self-start rounded-full px-[1.125rem] text-[0.8125rem] font-semibold"
                    style={"background: #{@accent}; color: #{@on_accent}"}
                  >
                    {label}
                  </span>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :segments, :list, required: true

  defp segments(assigns) do
    ~H"""
    <%= for segment <- @segments do %>
      <%= case segment do %>
        <% {:text, text} -> %>
          {text}
        <% {:var, _key, value} -> %>
          <mark>{value}</mark>
        <% {:bold, inner} -> %>
          <strong class="text-[#16170f]"><.segments segments={inner} /></strong>
        <% {:link, inner, _url} -> %>
          <span class="text-[#3f5c00] underline"><.segments segments={inner} /></span>
      <% end %>
    <% end %>
    """
  end

  defp preview_to(vars) do
    case vars["player"] do
      nil -> "cliente@exemplo.com"
      player -> String.downcase(String.replace(player, ~r/[^A-Za-z0-9]/, "")) <> "@…"
    end
  end

  @doc "A template's name, as the list shows it."
  def template_name("welcome"), do: gettext("Welcome")
  def template_name("reset"), do: gettext("Reset password")
  def template_name("purchase"), do: gettext("Purchase approved")
  def template_name("expiring"), do: gettext("VIP about to end")
  def template_name("delivery_failed"), do: gettext("Delivery failed")

  defp template_when("welcome", _settings), do: gettext("when the account is created")
  defp template_when("reset", _settings), do: gettext("link good for 30 minutes")
  defp template_when("purchase", _settings), do: gettext("when the payment is confirmed")

  defp template_when("expiring", settings),
    do:
      ngettext(
        "%{count} day before the end",
        "%{count} days before the end",
        settings.reminder_days || 0
      )

  defp template_when("delivery_failed", _settings),
    do: gettext("a server did not confirm the VIP")

  defp seconds(nil), do: "?"

  defp seconds(ms) do
    text = :erlang.float_to_binary(ms / 1000, decimals: 1)

    if Gettext.get_locale(HllConditionalActionsWeb.Gettext) == "pt_BR",
      do: String.replace(text, ".", ","),
      else: text
  end

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp parse_time(_other), do: nil
end
