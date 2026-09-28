defmodule HllConditionalActionsWeb.DiscordComponents do
  @moduledoc """
  The "Send a Discord message" action in the rule builder: its fields laid
  out in sections, and a preview drawn the way Discord shows the message.

  The preview is built by `HllConditionalActions.Discord.Message` - the same
  code the engine posts with - with placeholders left as written, so the
  limits and the embed shape it shows are the real ones.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.Discord.Message

  @embed_keys ~w(embed_title embed_description embed_fields embed_footer embed_thumbnail_url)
  @delivery_keys ~w(mode edit_key thread_id thread_name aggregate silent mention_role_ids
                    username avatar_url)

  attr :action, :any, required: true
  attr :parameters, :map, required: true
  attr :webhooks, :list, required: true, doc: "`{name, id}` pairs"
  attr :batch?, :boolean, default: false, doc: "whether the rule's trigger sweeps every player"

  def action_fields(assigns) do
    parameters = assigns.parameters

    assigns =
      assigns
      |> assign(:embed_open?, Enum.any?(@embed_keys, &present?(parameters[&1])))
      |> assign(
        :delivery_open?,
        Enum.any?(@delivery_keys -- ["mode", "aggregate", "silent"], &present?(parameters[&1])) or
          parameters["mode"] == "edit" or truthy?(parameters["aggregate"]) or
          truthy?(parameters["silent"])
      )

    ~H"""
    <div class="space-y-4">
      <div class="min-w-0 space-y-3">
        <div :if={@webhooks == []} class="rounded-box bg-warning/10 p-3 text-sm">
          {gettext("No Discord webhook is registered yet.")}
          <.link navigate={~p"/discord/new"} class="font-medium text-primary hover:underline">
            {gettext("Register one")}
          </.link>
        </div>

        <div class="flex items-end gap-2">
          <div class="min-w-0 flex-1">
            <.input
              type="select"
              id={field_id(@action, :webhook_id)}
              name={field_name(@action, :webhook_id)}
              value={@parameters["webhook_id"]}
              options={@webhooks}
              prompt={gettext("Choose a webhook")}
              label={Labels.action_param(:webhook_id)}
              no_margin
            />
          </div>

          <.link
            navigate={~p"/discord"}
            class="mb-2 shrink-0 text-xs text-muted hover:text-primary"
          >
            {gettext("Manage")}
          </.link>
        </div>

        <.text_param
          action={@action}
          key={:message}
          parameters={@parameters}
          type="textarea"
          help={
            if truthy?(@parameters["aggregate"]),
              do: gettext("Written once per player; the lines are joined into one message."),
              else: gettext("Plain text above the embed. Markdown works.")
          }
        />
        <details open={@embed_open?} class="group rounded-box border border-base-300">
          <summary class="flex cursor-pointer items-center gap-2 p-3 text-sm font-medium">
            <.icon name="hero-rectangle-group" class="size-4 text-muted" />{gettext("Embed")}
            <span class="text-xs font-normal text-muted">
              {gettext("the card with a coloured bar")}
            </span>
          </summary>

          <div class="grid gap-3 border-t border-base-300 p-3">
            <.text_param action={@action} key={:embed_title} parameters={@parameters} />
            <.text_param
              action={@action}
              key={:embed_description}
              parameters={@parameters}
              type="textarea"
            />
            <.text_param
              action={@action}
              key={:embed_fields}
              parameters={@parameters}
              type="textarea"
              placeholder={fields_example()}
              help={gettext("One per line, as Name | Value. Up to 25, shown side by side.")}
            /> <.text_param action={@action} key={:embed_footer} parameters={@parameters} />
            <.text_param
              action={@action}
              key={:embed_thumbnail_url}
              parameters={@parameters}
              placeholder="https://"
            />
            <.input
              type="color"
              id={field_id(@action, :embed_color)}
              name={field_name(@action, :embed_color)}
              value={@parameters["embed_color"] || "#5865F2"}
              label={Labels.action_param(:embed_color)}
              no_margin
              class="h-9 w-16"
            /> <.toggle action={@action} key={:embed_timestamp} parameters={@parameters} default />
          </div>
        </details>

        <details open={@delivery_open?} class="group rounded-box border border-base-300">
          <summary class="flex cursor-pointer items-center gap-2 p-3 text-sm font-medium">
            <.icon name="hero-adjustments-horizontal" class="size-4 text-muted" /> {gettext(
              "Delivery"
            )}
          </summary>

          <div class="grid gap-3 border-t border-base-300 p-3">
            <.input
              type="select"
              id={field_id(@action, :mode)}
              name={field_name(@action, :mode)}
              value={@parameters["mode"] || "send"}
              options={Labels.discord_mode_options()}
              label={Labels.action_param(:mode)}
              no_margin
            />
            <.text_param
              :if={@parameters["mode"] == "edit"}
              action={@action}
              key={:edit_key}
              parameters={@parameters}
              placeholder="{map_name}"
              help={
                gettext(
                  "Empty: a single message per server, edited forever. With a placeholder, a new message whenever its value changes."
                )
              }
            />
            <.text_param
              action={@action}
              key={:thread_name}
              parameters={@parameters}
              placeholder="{map_name}"
              help={gettext("Forum channels: opens the post once and keeps posting in it.")}
            />
            <.text_param
              action={@action}
              key={:thread_id}
              parameters={@parameters}
              help={gettext("Post inside an existing thread.")}
            />
            <.text_param
              action={@action}
              key={:mention_role_ids}
              parameters={@parameters}
              help={
                gettext(
                  "Nobody is pinged unless listed here. Write <@&id> in the text to mention the role."
                )
              }
            /> <.text_param action={@action} key={:username} parameters={@parameters} />
            <.text_param
              action={@action}
              key={:avatar_url}
              parameters={@parameters}
              placeholder="https://"
            />
            <div class="space-y-2">
              <.toggle action={@action} key={:silent} parameters={@parameters} />
              <.toggle
                :if={@batch?}
                action={@action}
                key={:aggregate}
                parameters={@parameters}
              />
            </div>
          </div>
        </details>
      </div>
      <.preview parameters={@parameters} webhook={webhook_name(@webhooks, @parameters)} />
    </div>
    """
  end

  attr :action, :any, required: true
  attr :key, :atom, required: true
  attr :parameters, :map, required: true
  attr :type, :string, default: "text"
  attr :help, :string, default: nil
  attr :placeholder, :string, default: nil

  defp text_param(assigns) do
    ~H"""
    <.input
      type={@type}
      id={field_id(@action, @key)}
      name={field_name(@action, @key)}
      value={@parameters[to_string(@key)]}
      label={Labels.action_param(@key)}
      placeholder={@placeholder}
      help_text={@help}
      rows={if @type == "textarea", do: "3"}
      no_margin
    />
    """
  end

  attr :action, :any, required: true
  attr :key, :atom, required: true
  attr :parameters, :map, required: true
  attr :default, :boolean, default: false

  defp toggle(assigns) do
    assigns =
      assign(
        assigns,
        :checked,
        case assigns.parameters[to_string(assigns.key)] do
          nil -> assigns.default
          value -> truthy?(value)
        end
      )

    ~H"""
    <label class="flex cursor-pointer items-center gap-2 self-end text-sm">
      <input type="hidden" name={field_name(@action, @key)} value="false" />
      <input
        type="checkbox"
        id={field_id(@action, @key)}
        name={field_name(@action, @key)}
        value="true"
        checked={@checked}
        class="pc-checkbox"
      /> {Labels.action_param(@key)}
    </label>
    """
  end

  # ── Preview ────────────────────────────────────────────────────────────────

  attr :parameters, :map, required: true
  attr :webhook, :string, default: nil

  def preview(assigns) do
    payload = Message.build(assigns.parameters, &(&1 || ""))
    embed = List.first(payload["embeds"] || [])

    assigns =
      assigns
      |> assign(:payload, payload)
      |> assign(:embed, embed)
      |> assign(:bar, bar_color(embed))
      |> assign(:empty?, Message.empty?(payload))

    ~H"""
    <div class="min-w-0 space-y-1.5">
      <p class="eyebrow text-muted">{gettext("Preview")}</p>

      <div class="rounded-box bg-[#313338] p-3 font-sans text-[0.9rem] leading-snug text-[#dbdee1]">
        <div class="flex gap-3">
          <img
            :if={@payload["avatar_url"]}
            src={@payload["avatar_url"]}
            alt=""
            class="size-9 shrink-0 rounded-full object-cover"
          />
          <div
            :if={!@payload["avatar_url"]}
            class="flex size-9 shrink-0 items-center justify-center rounded-full bg-[#5865f2] text-white"
          >
            <.icon name="hero-bolt" class="size-4" />
          </div>

          <div class="min-w-0 flex-1">
            <p class="flex flex-wrap items-center gap-1.5">
              <span class="font-medium text-white">
                {@payload["username"] || @webhook || "HLL Conditional Actions"}
              </span>

              <span class="rounded bg-[#5865f2] px-1 text-[0.625rem] font-semibold text-white">
                APP
              </span>
            </p>

            <p :if={@empty?} class="mt-1 italic text-[#949ba4]">
              {gettext("Write a text or an embed to see it here.")}
            </p>
            <p
              :if={@payload["content"]}
              class="mt-0.5 whitespace-pre-wrap break-words"
              phx-no-format
            >{@payload["content"]}</p>
            <div
              :if={@embed}
              class="mt-1.5 flex max-w-md overflow-hidden rounded bg-[#2b2d31]"
            >
              <div class="w-1 shrink-0" style={"background-color: #{@bar}"}></div>

              <div class="flex min-w-0 flex-1 gap-3 p-3">
                <div class="min-w-0 flex-1 space-y-1.5">
                  <p :if={@embed["title"]} class="font-semibold text-white break-words">
                    {@embed["title"]}
                  </p>
                  <p
                    :if={@embed["description"]}
                    class="whitespace-pre-wrap break-words text-sm"
                    phx-no-format
                  >{@embed["description"]}</p>
                  <div :if={@embed["fields"]} class="grid grid-cols-3 gap-2 pt-1">
                    <div :for={field <- @embed["fields"]} class="min-w-0 text-sm">
                      <p class="font-semibold text-white break-words">{field["name"]}</p>
                      <p class="whitespace-pre-wrap break-words" phx-no-format>{field["value"]}</p>
                    </div>
                  </div>

                  <p
                    :if={@embed["footer"] || @embed["timestamp"]}
                    class="pt-1 text-xs text-[#949ba4]"
                  >
                    {footer_text(@embed)}
                  </p>
                </div>

                <img
                  :if={@embed["thumbnail"]}
                  src={@embed["thumbnail"]["url"]}
                  alt=""
                  class="size-16 shrink-0 rounded object-cover"
                />
              </div>
            </div>
          </div>
        </div>
      </div>

      <p class="text-xs text-muted">
        {gettext(
          "Placeholders are filled when the rule fires. Values from players are escaped so they cannot add formatting or pings."
        )}
      </p>
    </div>
    """
  end

  defp footer_text(embed) do
    [get_in(embed, ["footer", "text"]), embed["timestamp"] && gettext("Today")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
  end

  defp bar_color(%{"color" => color}) when is_integer(color) do
    "#" <> (color |> Integer.to_string(16) |> String.pad_leading(6, "0"))
  end

  defp bar_color(_embed), do: "#1e1f22"

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp webhook_name(webhooks, parameters) do
    Enum.find_value(webhooks, fn {name, id} ->
      if to_string(id) == to_string(parameters["webhook_id"]), do: name
    end)
  end

  defp fields_example, do: gettext("Kills | {kills}\nDeaths | {deaths}")

  defp field_name(action, key), do: "#{action.name}[parameters][#{key}]"
  defp field_id(action, key), do: "#{action.id}_parameters_#{key}"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "on", "1"]
end
