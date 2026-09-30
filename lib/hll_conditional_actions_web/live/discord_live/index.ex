defmodule HllConditionalActionsWeb.DiscordLive.Index do
  @moduledoc """
  The Discord webhooks rules and modules post to.

  The list shows each webhook with its channel, sender, last delivery and
  who posts to it; the selected one opens its delivery log (the last seven
  days of rule deliveries, `HllConditionalActions.Discord.Deliveries`) and
  its editor on the right. A webhook is checked with Discord when its URL is
  saved and can be tested with one click.

  The URL is never shown again after saving - it is a secret - and leaving
  the field blank when editing keeps the stored one. Only its last four
  characters are shown, so the staff can tell which one is stored.
  """

  use HllConditionalActionsWeb, :live_view

  # Rules pick webhooks, so whoever manages rules manages webhooks.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Deliveries
  alias HllConditionalActions.Discord.Webhook
  alias HllConditionalActions.Servers
  alias HllConditionalActions.Servers.Server
  alias Phoenix.HTML.Form

  # Rows shown in the delivery log; older entries of the window are counted.
  @log_limit 60

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Discord"))
     |> assign(:zone, timezone())
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, %{"closed" => _closed}), do: select(socket, nil)

  defp apply_action(socket, :index, _params) do
    webhooks = socket.assigns.webhooks

    case Enum.find(webhooks, & &1.last_error) || List.first(webhooks) do
      nil -> select(socket, %Webhook{})
      webhook -> select(socket, webhook)
    end
  end

  defp apply_action(socket, :new, _params), do: select(socket, %Webhook{})

  defp apply_action(socket, :edit, %{"id" => id}),
    do: select(socket, Discord.get_webhook!(id))

  defp select(socket, nil), do: socket |> assign(:webhook, nil) |> assign(:form, nil)

  defp select(socket, webhook) do
    socket |> assign(:webhook, webhook) |> assign_form(Discord.change_webhook(webhook))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"webhook" => params}, socket) do
    changeset = Discord.change_webhook(socket.assigns.webhook, keep_url(socket, params))
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"webhook" => params}, socket) do
    params = keep_url(socket, params)

    result =
      case socket.assigns.webhook do
        %Webhook{id: nil} -> Discord.create_webhook(params)
        webhook -> Discord.update_webhook(webhook, params)
      end

    case result do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Webhook saved."))
         |> load()
         |> push_patch(to: ~p"/discord/#{webhook.id}/edit")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    webhook = Discord.get_webhook!(id)

    socket =
      case Discord.send_test(webhook, test_text()) do
        :ok ->
          put_flash(
            socket,
            :info,
            gettext("Test message sent to \"%{name}\".", name: webhook.name)
          )

        {:error, reason} ->
          put_flash(socket, :error, gettext("Discord refused it: %{reason}", reason: reason))
      end

    {:noreply, socket |> load() |> refresh_selected()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Discord.delete_webhook(Discord.get_webhook!(id)) do
      {:ok, _webhook} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Webhook removed."))
         |> load()
         |> push_patch(to: ~p"/discord")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Rules still post to this webhook. Change them first.")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove that webhook."))}
    end
  end

  # The URL input starts blank when editing; blank means "keep the stored one".
  defp keep_url(%{assigns: %{webhook: %Webhook{id: nil}}}, params), do: params

  defp keep_url(_socket, params) do
    case String.trim(Map.get(params, "url", "")) do
      "" -> Map.delete(params, "url")
      _url -> params
    end
  end

  defp load(socket) do
    socket
    # In the order they were registered, as the staff set them up.
    |> assign(:webhooks, Enum.sort_by(Discord.list_webhooks(), & &1.id))
    |> assign(:users, Deliveries.users())
    |> assign(:summaries, Deliveries.summaries())
  end

  # A test changes the selected webhook's status: read it again.
  defp refresh_selected(%{assigns: %{webhook: %Webhook{id: id}}} = socket) when is_integer(id) do
    assign(socket, :webhook, Discord.get_webhook!(id))
  end

  defp refresh_selected(socket), do: socket

  # The stored URL is never sent back to the browser: the form is built on a
  # copy of the webhook without it, after validation has seen the real one.
  defp assign_form(socket, changeset) do
    changeset = Map.update!(changeset, :data, &%{&1 | url: nil})
    assign(socket, :form, to_form(changeset))
  end

  # Times read in the zone most servers use: webhooks belong to no server.
  defp timezone do
    Servers.list_servers()
    |> Enum.map(&Server.timezone/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_zone, count} -> count end, fn -> {"Etc/UTC", 0} end)
    |> elem(0)
  end

  defp test_text do
    gettext("Test message from HLL Conditional Actions. If you can read this, the webhook works.")
  end

  # ── View helpers ───────────────────────────────────────────────────────────

  defp failing(webhooks), do: Enum.count(webhooks, & &1.last_error)

  defp selected?(%Webhook{id: id}, %Webhook{id: id}) when is_integer(id), do: true
  defp selected?(_webhook, _selected), do: false

  defp summary(summaries, %Webhook{id: id}), do: Deliveries.summary(summaries, id)

  defp initial(nil), do: "?"

  defp initial(name) do
    case name |> String.trim() |> String.first() do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp sender_name(webhook), do: webhook.username || webhook.remote_name || webhook.name

  # Each webhook keeps one of four tints, so the senders tell apart at a glance.
  defp avatar_tone(%Webhook{id: id}) when is_integer(id) do
    Enum.at(
      [
        "bg-primary text-primary-content",
        "bg-accent/15 text-accent",
        "discord-avatar-teal",
        "bg-allies/16 text-allies"
      ],
      rem(id + 3, 4)
    )
  end

  defp avatar_tone(_webhook), do: "bg-allies/16 text-allies"

  # The sender as the editor shows it: what is being typed, or what is stored.
  defp form_sender(form, webhook) do
    case Form.input_value(form, :username) do
      name when is_binary(name) and name != "" ->
        name

      _blank ->
        webhook.remote_name || blank_to_nil(Form.input_value(form, :name)) ||
          "HLL Conditional Actions"
    end
  end

  defp form_avatar(form) do
    case Form.input_value(form, :avatar_url) do
      "https://" <> _rest = url -> url
      _other -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  # The last four characters of the stored token: enough to tell which URL
  # is stored, never enough to use it.
  defp url_tail(%Webhook{url: url}) when is_binary(url) do
    token = url |> String.trim_trailing("/") |> String.split("/") |> List.last()
    if String.length(token) >= 8, do: String.slice(token, -4, 4)
  end

  defp url_tail(_webhook), do: nil

  defp url_hint(tail) do
    marker = "\u0000"

    gettext(
      "Stored encrypted, never shown again. Leave blank to keep the current one, which ends in %{tail}.",
      tail: marker
    )
    |> String.split(marker, parts: 2)
    |> case do
      [before, rest] -> {before, "…" <> tail, rest}
      [text] -> {text, nil, ""}
    end
  end

  # The state the "Last delivery" column shows.
  defp last_delivery(webhook, summary) do
    cond do
      webhook.last_error ->
        %{
          state: :error,
          code: Deliveries.http_status(webhook.last_error),
          at: webhook.last_error_at,
          streak: summary.streak
        }

      webhook.last_delivered_at ->
        code =
          case summary.last do
            %{status: :delivered, http: http} -> http
            _other -> nil
          end

        %{state: :ok, code: code, at: webhook.last_delivered_at, streak: 0}

      true ->
        %{state: :none, code: nil, at: nil, streak: 0}
    end
  end

  defp delivery_meta(%{state: :error} = last, zone) do
    [
      short_time(last.at, zone),
      last.streak > 0 &&
        ngettext("%{count} failure", "%{count} failures", last.streak, count: last.streak)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp delivery_meta(last, zone) do
    [short_time(last.at, zone), last.code]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # "21:47" today, "28/09 21:47" before.
  defp short_time(nil, _zone), do: nil

  defp short_time(at, zone) do
    local = local(at, zone)

    if DateTime.to_date(local) == DateTime.to_date(local(DateTime.utc_now(), zone)),
      do: Calendar.strftime(local, "%H:%M"),
      else: Calendar.strftime(local, "%d/%m %H:%M")
  end

  defp log_time(at, zone) do
    local = local(at, zone)

    if DateTime.to_date(local) == DateTime.to_date(local(DateTime.utc_now(), zone)),
      do: Calendar.strftime(local, "%H:%M:%S"),
      else: Calendar.strftime(local, "%d/%m %H:%M")
  end

  defp local(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _error -> at
    end
  end

  defp log_status(%{http: http}) when is_integer(http), do: Integer.to_string(http)
  defp log_status(%{status: :delivered}), do: gettext("ok")
  defp log_status(_entry), do: "—"

  defp log_message(%{status: :delivered}), do: gettext("delivered")
  defp log_message(%{detail: detail}), do: Deliveries.reason(detail) || gettext("failed")

  # What made the rule post: "!discord from Santos", or the rule itself.
  defp log_source(%{command: command, player_name: player}) when is_binary(command) do
    if player,
      do: gettext("%{command} from %{player}", command: "!" <> command, player: player),
      else: "!" <> command
  end

  defp log_source(%{rule_name: rule, player_name: player}) when is_binary(player),
    do: "#{rule} · #{player}"

  defp log_source(%{rule_name: rule}), do: rule

  defp banner(webhook, summary, zone) do
    code = Deliveries.http_status(webhook.last_error)
    since = short_time(summary.streak_since || webhook.last_error_at, zone)

    title =
      cond do
        code && since -> gettext("%{code} since %{time}.", code: code, time: since)
        since -> gettext("Failing since %{time}.", time: since)
        true -> gettext("Failing.")
      end

    text =
      if code in [401, 403, 404],
        do: gettext("The webhook was deleted or replaced on Discord. Paste the new URL below."),
        else: webhook.last_error

    {title, text}
  end

  defp now_time(zone), do: Calendar.strftime(local(DateTime.utc_now(), zone), "%H:%M")

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Discord")}
      crumb={gettext("Settings") <> " / " <> gettext("Integrations")}
      back={~p"/settings"}
      back_label={gettext("Back to settings")}
      global_search={false}
      scope={false}
      bell={false}
    >
      <:actions>
        <.link
          id="discord-new"
          patch={~p"/discord/new"}
          class="flex h-12 items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 text-sm transition-colors hover:border-primary/50 max-sm:w-12 max-sm:justify-center max-sm:px-0"
        >
          <.icon name="hero-plus" class="size-[1.125rem] shrink-0" />
          <span class="max-sm:sr-only">{gettext("New webhook")}</span>
        </.link>
      </:actions>

      <div class="grid gap-5 xl:min-h-[56.25rem] xl:grid-cols-[minmax(0,1fr)_27.5rem]">
        <section
          id="webhook-list"
          aria-label={gettext("Webhooks")}
          class="flex min-w-0 flex-col gap-1 rounded-panel bg-base-100 px-3 pb-4 pt-5 sm:px-4"
        >
          <div class="flex items-baseline gap-2.5 px-2 pb-2.5">
            <h2 class="grow font-display text-[1.25rem] font-semibold leading-[1.2]">
              {gettext("Webhooks")}
            </h2>
            <span id="webhook-count" class="text-[0.8125rem] text-muted">
              {length(@webhooks)}
              <span :if={failing(@webhooks) > 0}>
                ·
                <span class="text-error">{ngettext(
                  "%{count} failing",
                  "%{count} failing",
                  failing(@webhooks),
                  count: failing(@webhooks)
                )}</span>
              </span>
            </span>
          </div>

          <div :if={@webhooks == []} class="flex flex-col items-center gap-3 px-4 py-10 text-center">
            <.icon_tile icon="hero-chat-bubble-left-right" tone="allies" size="lg" />
            <h3 class="font-display text-lg font-semibold">{gettext("No webhook yet")}</h3>
            <p class="max-w-md text-sm text-muted">
              {gettext(
                "In Discord, open the channel settings, Integrations, Webhooks, and copy a webhook URL. Register it here and pick it in any rule."
              )}
            </p>
          </div>

          <div
            :if={@webhooks != []}
            class="discord-grid grid items-center gap-4 px-3 py-2 text-xs text-muted max-lg:hidden"
            aria-hidden="true"
          >
            <span>{gettext("Webhook and channel")}</span>
            <span>{gettext("Sender")}</span>
            <span>{gettext("Last delivery")}</span>
            <span>{gettext("Used by")}</span>
          </div>

          <.link
            :for={webhook <- @webhooks}
            id={"webhook-#{webhook.id}"}
            patch={~p"/discord/#{webhook.id}/edit"}
            aria-current={selected?(webhook, @webhook) && "true"}
            class={[
              "discord-grid grid items-center gap-4 rounded-[1.125rem] border px-3 py-3.5 transition-colors",
              if(selected?(webhook, @webhook),
                do: "border-line-strong bg-secondary",
                else: "border-transparent border-t-line-soft hover:bg-secondary/60"
              )
            ]}
          >
            <span class="flex min-w-0 flex-col gap-[0.1875rem]">
              <strong class="truncate text-sm font-semibold">{webhook.name}</strong>
              <span
                :if={webhook.channel_label}
                id={"webhook-#{webhook.id}-channel"}
                class="truncate font-mono text-xs text-muted"
              >
                {webhook.channel_label}
              </span>
              <span :if={!webhook.channel_label} class="truncate text-xs text-muted">
                {gettext("No channel label")}
              </span>
            </span>

            <span class="flex min-w-0 items-center gap-2.5 max-lg:hidden">
              <img
                :if={webhook.avatar_url}
                src={webhook.avatar_url}
                alt=""
                class="size-8 shrink-0 rounded-full object-cover"
              />
              <span
                :if={!webhook.avatar_url}
                class={[
                  "flex size-8 shrink-0 items-center justify-center rounded-full text-[0.8125rem] font-bold",
                  avatar_tone(webhook)
                ]}
              >
                {initial(sender_name(webhook))}
              </span>
              <span class="truncate text-[0.8125rem]">{sender_name(webhook)}</span>
            </span>

            <.last_delivery
              id={"webhook-#{webhook.id}-last"}
              last={last_delivery(webhook, summary(@summaries, webhook))}
              zone={@zone}
            />

            <span class="flex flex-wrap gap-1 max-lg:hidden">
              <.user_chip
                :for={user <- Map.get(@users, webhook.id, [])}
                user={user}
                selected={selected?(webhook, @webhook)}
              />
              <span :if={Map.get(@users, webhook.id, []) == []} class="text-xs text-muted">
                {gettext("Nobody posts here yet")}
              </span>
            </span>
          </.link>

          <.delivery_log
            :if={@webhook && @webhook.id}
            webhook={@webhook}
            summary={summary(@summaries, @webhook)}
            used_by_modules?={Enum.any?(Map.get(@users, @webhook.id, []), &(&1.kind != :rule))}
            zone={@zone}
          />
        </section>

        <.editor
          :if={@webhook}
          webhook={@webhook}
          form={@form}
          summary={summary(@summaries, @webhook)}
          zone={@zone}
        />

        <section
          :if={!@webhook}
          id="webhook-help"
          aria-label={gettext("How to get a webhook URL")}
          class="flex flex-col gap-3 self-start rounded-panel bg-base-100 p-5 sm:p-6"
        >
          <.icon_tile icon="hero-chat-bubble-left-right" tone="allies" size="lg" />
          <h2 class="font-display text-[1.25rem] font-semibold leading-[1.2]">
            {gettext("How to get a webhook URL")}
          </h2>
          <p class="text-sm text-subtle">
            {gettext(
              "In Discord, open the channel settings, Integrations, Webhooks, and copy a webhook URL. Register it here and pick it in any rule."
            )}
          </p>
          <p class="text-sm text-subtle">
            {gettext("Saving checks the URL with Discord. Pick a webhook on the left to edit it.")}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # ── Components ─────────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :last, :map, required: true
  attr :zone, :string, required: true

  defp last_delivery(assigns) do
    ~H"""
    <span id={@id} class="flex min-w-0 flex-col gap-[0.1875rem] max-lg:items-end">
      <%= case @last.state do %>
        <% :error -> %>
          <span class="flex items-center gap-1.5 text-[0.8125rem] font-semibold text-error">
            <.icon name="hero-x-mark" class="size-3.5 shrink-0" />
            {if @last.code,
              do: gettext("error %{code}", code: @last.code),
              else: gettext("error")}
          </span>
        <% :ok -> %>
          <span class="flex items-center gap-1.5 text-[0.8125rem] font-semibold text-primary">
            <.icon name="hero-check" class="size-3.5 shrink-0" /> {gettext("ok")}
          </span>
        <% :none -> %>
          <span class="text-[0.8125rem] text-muted">{gettext("Nothing sent yet")}</span>
      <% end %>
      <span :if={@last.at} class="truncate font-mono text-xs text-muted">
        {delivery_meta(@last, @zone)}
      </span>
    </span>
    """
  end

  attr :user, :map, required: true
  attr :selected, :boolean, default: false

  defp user_chip(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2 py-[0.1875rem] text-[0.6875rem]",
      case @user.kind do
        :rule -> if(@selected, do: "bg-base-300 text-subtle", else: "bg-secondary text-subtle")
        _module -> "bg-accent/13 text-accent"
      end
    ]}>
      {case @user.kind do
        :rule -> @user.name
        :tickets -> gettext("Tickets module")
        :vip_shop -> gettext("VIP shop")
      end}
    </span>
    """
  end

  attr :webhook, Webhook, required: true
  attr :summary, :map, required: true
  attr :used_by_modules?, :boolean, default: false
  attr :zone, :string, required: true

  defp delivery_log(assigns) do
    assigns =
      assigns
      |> assign(:entries, Enum.take(assigns.summary.log, @log_limit))
      |> assign(:older, max(length(assigns.summary.log) - @log_limit, 0))

    ~H"""
    <div
      id="delivery-log"
      class="mt-3.5 flex grow flex-col gap-2 rounded-[1.25rem] border border-line-soft bg-[var(--discord-well)] px-4 py-4 sm:px-[1.125rem]"
    >
      <div class="mb-1 flex items-baseline gap-2">
        <strong class="grow text-sm font-semibold">
          {gettext("Latest deliveries · %{name}", name: @webhook.name)}
        </strong>
        <span class="shrink-0 text-xs text-muted">
          {ngettext("kept %{count} day", "kept %{count} days", Deliveries.retention_days(),
            count: Deliveries.retention_days()
          )}
        </span>
      </div>

      <div :if={@entries != []} class="flex max-h-[19rem] flex-col gap-2 overflow-y-auto">
        <div
          :for={{entry, index} <- Enum.with_index(@entries)}
          id={"delivery-#{index}"}
          class="discord-log-row font-mono text-xs"
        >
          <span class="text-muted">{log_time(entry.at, @zone)}</span>
          <span class={if entry.status == :delivered, do: "text-primary", else: "text-error"}>
            {log_status(entry)}
          </span>
          <span class="truncate text-subtle" title={entry.detail}>{log_message(entry)}</span>
          <span class="discord-log-source truncate text-muted">{log_source(entry)}</span>
        </div>
      </div>

      <p :if={@older > 0} class="text-xs text-muted">
        {gettext("and %{count} older in the window", count: @older)}
      </p>

      <p :if={@entries == []} id="delivery-log-empty" class="text-[0.8125rem] text-muted">
        {gettext("No rule delivered to this webhook in the last %{count} days.",
          count: Deliveries.retention_days()
        )}
      </p>

      <p :if={@used_by_modules?} class="text-xs leading-[1.45] text-muted">
        {gettext(
          "Tickets and the VIP shop post here too; their messages update the status above but are not listed."
        )}
      </p>

      <p class="mt-auto pt-2 text-xs leading-[1.45] text-muted">
        {gettext(
          "When Discord is down we try again, up to 5 times. A message Discord refuses, like one sent to a deleted webhook, is not resent: the error shows here and on the rule's run."
        )}
      </p>
    </div>
    """
  end

  attr :webhook, Webhook, required: true
  attr :form, :any, required: true
  attr :summary, :map, required: true
  attr :zone, :string, required: true

  defp editor(assigns) do
    tail = url_tail(assigns.webhook)

    assigns =
      assigns
      |> assign(:tail, tail)
      |> assign(:hint, tail && url_hint(tail))
      |> assign(
        :banner,
        assigns.webhook.last_error && banner(assigns.webhook, assigns.summary, assigns.zone)
      )

    ~H"""
    <section
      id="webhook-editor"
      aria-label={
        if @webhook.id,
          do: gettext("Edit webhook %{name}", name: @webhook.name),
          else: gettext("New webhook")
      }
      class="flex min-w-0 flex-col rounded-panel bg-base-100 p-5 sm:p-[1.375rem]"
    >
      <.form
        for={@form}
        id="webhook-form"
        phx-change="validate"
        phx-submit="save"
        class="flex grow flex-col gap-3.5"
      >
        <div class="flex items-center gap-2.5">
          <span class="flex min-w-0 grow flex-col gap-0.5">
            <span class="text-xs uppercase tracking-[0.06em] text-muted">
              {if @webhook.id, do: gettext("Edit webhook"), else: gettext("New webhook")}
            </span>
            <h2 class="truncate font-display text-[1.375rem] font-semibold leading-[1.2]">
              {@webhook.name || gettext("New webhook")}
            </h2>
          </span>
          <.link
            id="webhook-editor-close"
            patch={~p"/discord?closed=1"}
            aria-label={gettext("Close editor")}
            class="flex size-10 shrink-0 items-center justify-center rounded-full border border-base-300 bg-secondary text-subtle transition-colors hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.link>
        </div>

        <div
          :if={@banner}
          id="webhook-error"
          class="flex gap-2.5 rounded-2xl border border-error/30 bg-error/10 px-3.5 py-3"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-error" />
          <span class="text-[0.8125rem] leading-[1.45]">
            <strong class="font-semibold text-error">{elem(@banner, 0)}</strong>
            {elem(@banner, 1)}
          </span>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            label_class="discord-label"
            placeholder={gettext("Admin log")}
            class="discord-field"
            no_margin
          />
          <.input
            field={@form[:channel_label]}
            type="text"
            label={gettext("Channel label")}
            label_class="discord-label"
            placeholder="#canal"
            class="discord-field font-mono text-[0.8125rem]"
            no_margin
          />
        </div>

        <div class="flex flex-col gap-2">
          <label for="webhook-url" class="discord-label">{gettext("Webhook URL")}</label>
          <div class="relative">
            <.icon
              name="hero-lock-closed"
              class="pointer-events-none absolute left-3.5 top-[0.9375rem] size-4 text-muted"
            />
            <.input
              field={@form[:url]}
              id="webhook-url"
              type="password"
              label_class="hidden"
              placeholder="https://discord.com/api/webhooks/…"
              class="discord-field pl-10 font-mono text-[0.8125rem]"
              autocomplete="off"
              no_margin
              required={is_nil(@webhook.id)}
            />
          </div>
          <span id="webhook-url-hint" class="text-xs leading-[1.45] text-muted">
            <%= if @hint do %>
              {elem(@hint, 0)}<span class="font-mono text-subtle">{elem(@hint, 1)}</span>{elem(
                @hint,
                2
              )}
            <% else %>
              {gettext("Stored encrypted, never shown again.")}
            <% end %>
          </span>
        </div>

        <div class="grid grid-cols-[2.875rem_minmax(0,1fr)] items-end gap-3">
          <img
            :if={form_avatar(@form)}
            src={form_avatar(@form)}
            alt=""
            class="size-[2.875rem] rounded-full object-cover"
          />
          <span
            :if={!form_avatar(@form)}
            aria-hidden="true"
            class={[
              "flex size-[2.875rem] items-center justify-center rounded-full text-lg font-bold",
              avatar_tone(@webhook)
            ]}
          >
            {initial(form_sender(@form, @webhook))}
          </span>
          <.input
            field={@form[:username]}
            type="text"
            label={gettext("Sender name")}
            label_class="discord-label"
            placeholder="HLL Conditional Actions"
            class="discord-field"
            no_margin
          />
        </div>

        <div class="flex flex-col gap-2">
          <label for="webhook-avatar" class="discord-label">
            {gettext("Avatar")}
            <span class="font-normal text-muted">· {gettext("image URL, optional")}</span>
          </label>
          <.input
            field={@form[:avatar_url]}
            id="webhook-avatar"
            type="url"
            label_class="hidden"
            placeholder={gettext("No image, we show the initial")}
            class="discord-field"
            no_margin
          />
        </div>

        <div
          id="webhook-preview"
          class="flex gap-3 rounded-2xl border border-line-soft bg-[var(--discord-well)] px-3.5 py-3"
        >
          <img
            :if={form_avatar(@form)}
            src={form_avatar(@form)}
            alt=""
            class="size-9 shrink-0 rounded-full object-cover"
          />
          <span
            :if={!form_avatar(@form)}
            aria-hidden="true"
            class={[
              "flex size-9 shrink-0 items-center justify-center rounded-full text-sm font-bold",
              avatar_tone(@webhook)
            ]}
          >
            {initial(form_sender(@form, @webhook))}
          </span>
          <span class="flex min-w-0 flex-col gap-[0.1875rem]">
            <span class="flex items-center gap-1.5 text-[0.8125rem]">
              <strong class="truncate font-semibold">{form_sender(@form, @webhook)}</strong>
              <span class="rounded bg-[var(--discord-blurple)] px-[0.3125rem] py-px text-[0.625rem] font-bold text-white">
                APP
              </span>
              <span class="font-mono text-[0.6875rem] text-muted">{now_time(@zone)}</span>
            </span>
            <span class="text-[0.8125rem] leading-[1.45] text-subtle">{test_text()}</span>
          </span>
        </div>

        <span class="grow"></span>

        <div class="flex items-center gap-2">
          <button
            :if={@webhook.id}
            type="button"
            id="webhook-test"
            phx-click="test"
            phx-value-id={@webhook.id}
            phx-disable-with={gettext("Sending...")}
            class="flex h-12 shrink-0 items-center gap-2 rounded-full border border-base-300 bg-secondary px-[1.125rem] text-sm transition-colors hover:border-primary/50"
          >
            <.icon name="hero-arrow-right" class="size-4" /> {gettext("Send a test")}
          </button>
          <button
            type="submit"
            id="webhook-save"
            phx-disable-with={gettext("Checking with Discord...")}
            class="h-12 grow rounded-full bg-primary text-sm font-semibold text-primary-content transition-opacity hover:opacity-90"
          >
            {gettext("Save")}
          </button>
        </div>
        <button
          :if={@webhook.id}
          type="button"
          id="webhook-delete"
          phx-click="delete"
          phx-value-id={@webhook.id}
          data-confirm={gettext("Delete the webhook \"%{name}\"?", name: @webhook.name)}
          class="h-8 self-start text-[0.8125rem] text-error hover:underline"
        >
          {gettext("Delete webhook")}
        </button>
      </.form>
    </section>
    """
  end
end
