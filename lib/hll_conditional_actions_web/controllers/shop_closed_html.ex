defmodule HllConditionalActionsWeb.ShopClosedHTML do
  @moduledoc """
  What visitors see while the admin keeps the shop closed: the storefront's
  frame with "Coming soon", instead of a missing page.
  """

  use HllConditionalActionsWeb, :html

  alias HllConditionalActionsWeb.ShopComponents

  attr :settings, :map, required: true

  def show(assigns) do
    ~H"""
    <ShopComponents.shell settings={@settings} nav={false} menu={false}>
      <section
        id="shop-closed"
        class="flex flex-1 flex-col items-center justify-center gap-4 px-6 py-24 text-center"
      >
        <p class="text-sm font-semibold uppercase tracking-[0.12em] opacity-70">
          {@settings.shop_title || gettext("VIP shop")}
        </p>
        <h1 class="font-display text-[2.5rem] font-bold leading-tight tracking-[-0.02em] sm:text-[3.5rem]">
          {gettext("Coming soon")}
        </h1>
        <p class="max-w-md text-base opacity-80">
          {gettext("The shop is closed for now. Come back in a little while.")}
        </p>
      </section>
    </ShopComponents.shell>
    """
  end
end
