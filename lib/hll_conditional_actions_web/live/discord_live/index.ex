defmodule HllConditionalActionsWeb.DiscordLive.Index do
  @moduledoc """
  The Discord webhooks rules can post to.

  A webhook is checked with Discord when it is saved, can be tested with one
  click, and shows its last delivery or error, so a webhook somebody deleted
  on Discord's side is noticed here instead of in a silent channel.

  The URL is never shown again after saving - it is a secret - and leaving
  the field blank when editing keeps the stored one.
  """

  use HllConditionalActionsWeb, :live_view

  # Rules pick webhooks, so whoever manages rules manages webhooks.
  on_mount {HllConditionalActionsWeb.UserAuth, {:ensure_permission, :manage_integrations}}

  alias HllConditionalActions.Discord
  alias HllConditionalActions.Discord.Webhook

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Discord")) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:webhook, nil) |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    webhook = %Webhook{}
    socket |> assign(:webhook, webhook) |> assign_form(Discord.change_webhook(webhook))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    webhook = Discord.get_webhook!(id)
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
      {:ok, _webhook} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Webhook saved."))
         |> push_navigate(to: ~p"/discord")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    webhook = Discord.get_webhook!(id)

    text =
      gettext(
        "Test message from HLL Conditional Actions. If you can read this, the webhook works."
      )

    socket =
      case Discord.send_test(webhook, text) do
        :ok ->
          put_flash(
            socket,
            :info,
            gettext("Test message sent to \"%{name}\".", name: webhook.name)
          )

        {:error, reason} ->
          put_flash(socket, :error, gettext("Discord refused it: %{reason}", reason: reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Discord.delete_webhook(Discord.get_webhook!(id)) do
      {:ok, _webhook} ->
        {:noreply, socket |> put_flash(:info, gettext("Webhook removed.")) |> load()}

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
    |> assign(:webhooks, Discord.list_webhooks())
    |> assign(:usage, Discord.usage())
  end

  # The stored URL is never sent back to the browser: the form is built on a
  # copy of the webhook without it, after validation has seen the real one.
  defp assign_form(socket, changeset) do
    changeset = Map.update!(changeset, :data, &%{&1 | url: nil})
    assign(socket, :form, to_form(changeset))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      nav={assigns[:nav]}
      page_title={gettext("Discord")}
      page_subtitle={gettext("The webhooks your rules post to")}
    >
      <:actions>
        <.button
          link_type="live_patch"
          to={~p"/discord/new"}
          size="sm"
          color="primary"
          icon="hero-plus"
          label={gettext("New webhook")}
        />
      </:actions>

      <.empty_state
        :if={@webhooks == []}
        icon="hero-chat-bubble-left-right"
        title={gettext("No webhook yet")}
        description={
          gettext(
            "In Discord, open the channel settings, Integrations, Webhooks, and copy a webhook URL. Register it here and pick it in any rule."
          )
        }
      >
        <:action>
          <.button
            link_type="live_patch"
            to={~p"/discord/new"}
            size="sm"
            color="primary"
            label={gettext("Register a webhook")}
          />
        </:action>
      </.empty_state>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <div
          :for={webhook <- @webhooks}
          id={"webhook-#{webhook.id}"}
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="flex h-full flex-col gap-3 p-4 sm:p-5">
            <div class="flex items-start justify-between gap-2">
              <div class="flex min-w-0 items-center gap-2.5">
                <div class="flex size-9 shrink-0 items-center justify-center rounded-field bg-[#5865f2]/10 text-[#5865f2]">
                  <.icon name="hero-chat-bubble-left-right" class="size-4" />
                </div>

                <div class="min-w-0">
                  <h2 class="truncate font-semibold leading-tight">{webhook.name}</h2>

                  <p class="truncate text-xs text-muted">
                    {webhook.remote_name || gettext("Not checked with Discord yet")}
                  </p>
                </div>
              </div>

              <.tone_badge :if={webhook.last_error} tone="error" icon="hero-exclamation-triangle">
                {gettext("Failing")}
              </.tone_badge>

              <.tone_badge :if={!webhook.last_error && webhook.last_delivered_at} tone="success">
                {gettext("Working")}
              </.tone_badge>
            </div>

            <p :if={webhook.last_error} class="rounded-field bg-error/10 p-2 text-xs text-error">
              {webhook.last_error}
            </p>

            <dl class="grid grid-cols-2 gap-2 text-xs">
              <div>
                <dt class="text-muted">{gettext("Rules using it")}</dt>

                <dd class="font-medium">{Map.get(@usage, webhook.id, 0)}</dd>
              </div>

              <div>
                <dt class="text-muted">{gettext("Last delivery")}</dt>

                <dd class="font-medium">
                  <.local_time id={"webhook-#{webhook.id}-delivered"} at={webhook.last_delivered_at} />
                </dd>
              </div>
            </dl>

            <div class="mt-auto flex flex-wrap items-center justify-end gap-1 pt-2">
              <.button
                type="button"
                size="xs"
                variant="ghost"
                color="gray"
                phx-click="test"
                phx-value-id={webhook.id}
                phx-disable-with={gettext("Sending...")}
                label={gettext("Send a test")}
              />
              <.button
                link_type="live_patch"
                to={~p"/discord/#{webhook.id}/edit"}
                size="xs"
                variant="ghost"
                color="gray"
                label={gettext("Edit")}
              />
              <.button
                type="button"
                size="xs"
                variant="ghost"
                color="danger"
                phx-click="delete"
                phx-value-id={webhook.id}
                data-confirm={gettext("Remove the webhook \"%{name}\"?", name: webhook.name)}
                label={gettext("Remove")}
              />
            </div>
          </div>
        </div>
      </div>

      <.modal
        :if={@live_action in [:new, :edit]}
        id="webhook-modal"
        title={if @webhook.id, do: gettext("Edit webhook"), else: gettext("New webhook")}
        on_cancel={JS.patch(~p"/discord")}
        class="max-w-xl"
      >
        <.form
          for={@form}
          id="webhook-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4"
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("Admin log")}
            help_text={gettext("How rules and exported files refer to it.")}
            required
          />
          <.input
            field={@form[:url]}
            type="password"
            label={gettext("Webhook URL")}
            placeholder={
              if @webhook.id,
                do: gettext("Leave blank to keep the current URL"),
                else: "https://discord.com/api/webhooks/..."
            }
            help_text={gettext("Stored encrypted and never shown again.")}
            autocomplete="off"
            required={is_nil(@webhook.id)}
          />
          <.input
            field={@form[:username]}
            type="text"
            label={gettext("Sender name")}
            placeholder="HLL Conditional Actions"
            help_text={gettext("Optional. A rule can still set its own.")}
          />
          <.input
            field={@form[:avatar_url]}
            type="url"
            label={gettext("Sender avatar URL")}
            placeholder="https://"
          />
          <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
            <.button
              link_type="live_patch"
              to={~p"/discord"}
              size="sm"
              variant="ghost"
              color="gray"
              label={gettext("Cancel")}
            />
            <.button
              type="submit"
              size="sm"
              color="primary"
              phx-disable-with={gettext("Checking with Discord...")}
              label={gettext("Save")}
            />
          </div>
        </.form>
      </.modal>
    </Layouts.app>
    """
  end
end
