defmodule HllConditionalActionsWeb.ShopLive.AuthParts do
  @moduledoc """
  What the shop's account screens share: the picture beside the form, its
  headline and the benefits over it.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActions.VipShop.Design
  alias HllConditionalActionsWeb.ShopComponents

  @doc """
  The picture of an account screen: the admin's own, else the banner, else
  a map picked for the screen, with its name.
  """
  @spec auth_picture(map(), String.t()) :: %{src: String.t(), caption: String.t() | nil}
  def auth_picture(settings, screen) do
    image_id = Design.get(settings.design)["auth"]["image_id"] || settings.banner_asset_id

    if image_id do
      %{src: ~p"/shop/assets/#{image_id}", caption: nil}
    else
      {file, caption} = screen_map(screen)
      %{src: "/images/maps/hll/#{file}.webp", caption: caption}
    end
  end

  defp screen_map("login"), do: {"hurtgenforest-day", gettext("Hürtgen Forest · day")}
  defp screen_map("register"), do: {"kursk-day", gettext("Kursk · day")}
  defp screen_map("forgot"), do: {"hill400-dusk", gettext("Hill 400 · dusk")}
  defp screen_map(_reset), do: {"foy-day", gettext("Foy · day")}

  @doc "A text of the account screens: the admin's, or the default."
  @spec auth_text(map(), String.t()) :: String.t() | nil
  def auth_text(settings, key) do
    get_in(Design.get(settings.design), ["auth", "texts", key]) ||
      ShopComponents.auth_default(key)
  end

  @doc "Whether the admin wants the benefits over the picture."
  @spec show_benefits?(map()) :: boolean()
  def show_benefits?(settings), do: Design.get(settings.design)["auth"]["show_benefits"] != false

  attr :servers, :list, default: []

  @doc "The benefits as chips over the picture."
  def benefit_chips(assigns) do
    ~H"""
    <div class="mt-8 flex flex-wrap gap-2">
      <span
        :for={
          label <- [
            gettext("Front of the queue"),
            gettext("Reserved slot"),
            ngettext("On the server", "On the %{count} servers", max(length(@servers), 1))
          ]
        }
        class="shop-glass flex h-8 items-center gap-1.5 rounded-full px-3 text-[0.8125rem]"
      >
        <.icon name="hero-check" class="size-3.5 text-[var(--sh-img-accent)]" />{label}
      </span>
    </div>
    """
  end

  @doc "What an account gives, as three cards over the picture."
  def account_cards(assigns) do
    ~H"""
    <div class="mt-8 grid max-w-[40rem] grid-cols-3 gap-2.5">
      <div
        :for={
          {icon, title, text} <- [
            {"hero-user", gettext("Your player saved"),
             gettext("Search by the in-game name only once.")},
            {"hero-bars-3-bottom-left", gettext("Orders live"),
             gettext("Paid, delivered, server by server.")},
            {"hero-gift", gettext("VIP as a gift"), gettext("Give it to any player on the server.")}
          ]
        }
        class="shop-glass flex flex-col gap-2 rounded-[1.125rem] px-4 py-3.5"
      >
        <.icon name={icon} class="size-[18px] text-[var(--sh-img-accent)]" />
        <strong class="text-sm font-semibold">{title}</strong>
        <span class="text-xs leading-[1.45] text-[var(--sh-img-text-3)]">{text}</span>
      </div>
    </div>
    """
  end

  @doc "An email with its middle hidden: \"p••••••••••i@exemplo.com\"."
  @spec mask_email(String.t() | nil) :: String.t()
  def mask_email(nil), do: ""

  def mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when byte_size(local) > 2 ->
        String.first(local) <> String.duplicate("•", 10) <> String.last(local) <> "@" <> domain

      _short ->
        email
    end
  end
end
