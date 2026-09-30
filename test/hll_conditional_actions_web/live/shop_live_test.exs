defmodule HllConditionalActionsWeb.ShopLiveTest do
  # Not async: the shop tests share the payment providers' rows, and inserting
  # them from parallel sandboxes deadlocks.
  use HllConditionalActionsWeb.ConnCase, async: false
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.Repo
  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Coupon, Grant, Package, Payments, Storefront}
  alias HllConditionalActions.VipShop.Storefront.OrderNote

  setup %{conn: conn} do
    server = server_fixture(%{name: "BR #1 Público"})

    {:ok, package} =
      VipShop.save_package(%Package{}, %{
        "name" => "VIP Trimestral",
        "description" => "Frente da fila\nVaga reservada",
        "price" => "49.90",
        "compare_at" => "59.70",
        "highlight" => "Mais escolhido",
        "currency" => "BRL",
        "duration_days" => 90,
        "server_ids" => [server.id]
      })

    {:ok, _stripe} =
      VipShop.update_provider("stripe", %{
        "enabled" => true,
        "credentials" => %{"secret_key" => "sk_test", "webhook_secret" => "whsec"}
      })

    %{conn: init_test_session(conn, %{}), server: server, package: package}
  end

  defp as_customer(conn, attrs \\ %{}) do
    {:ok, customer} =
      VipShop.register_customer(
        Map.merge(
          %{"name" => "Kowalski", "email" => "ko@example.com", "password" => "secret1234"},
          attrs
        )
      )

    {Plug.Conn.put_session(conn, :shop_customer_id, customer.id), customer}
  end

  defp all_sections do
    sections =
      Enum.map(
        HllConditionalActions.VipShop.Design.section_keys(),
        &%{"key" => &1, "enabled" => true}
      )

    {:ok, _settings} = VipShop.update_design(%{"sections" => sections})
  end

  # A CRCON that answers the public info and the players history.
  defp stub_crcon(players \\ []) do
    Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "get_public_info") ->
          Req.Test.json(conn, %{
            "result" => %{
              "player_count" => 98,
              "max_player_count" => 100,
              "queue_count" => 6,
              "player_count_by_team" => %{"allied" => 49, "axis" => 49},
              "current_map" => %{
                "map" => %{
                  "id" => "carentan_warfare",
                  "pretty_name" => "Carentan Warfare",
                  "game_mode" => "warfare",
                  "environment" => "dusk",
                  "image_name" => "carentan-dusk.webp",
                  "map" => %{"id" => "carentan", "pretty_name" => "Carentan"}
                }
              }
            },
            "failed" => false
          })

        String.ends_with?(conn.request_path, "get_players_history") ->
          Req.Test.json(conn, %{"result" => %{"players" => players}, "failed" => false})

        true ->
          Req.Test.json(conn, %{"result" => %{}, "failed" => false})
      end
    end)
  end

  describe "the storefront" do
    test "shows the hero, the packages, the servers live and the questions", %{
      conn: conn,
      package: package,
      server: server
    } do
      stub_crcon()
      all_sections()
      {:ok, view, _html} = live(conn, ~p"/shop")
      html = render_async(view)

      assert has_element?(view, "#shop.shop-theme-tactical")
      assert has_element?(view, "#shop-hero")
      assert has_element?(view, "#package-#{package.id}.shop-highlight")
      assert has_element?(view, "#buy-#{package.id}")
      assert has_element?(view, "#duvidas")
      assert has_element?(view, "#server-#{server.id}")
      assert html =~ "98"
      assert has_element?(view, "#hero-live")
    end

    test "paints with the theme the admin picked", %{conn: conn} do
      {:ok, _settings} = VipShop.update_design(%{"theme" => "desert"})
      {:ok, view, _html} = live(conn, ~p"/shop")
      assert has_element?(view, "#shop.shop-theme-desert")
    end

    test "an admin's accent colour overrides the theme's", %{conn: conn} do
      {:ok, _settings} = VipShop.update_design(%{"theme" => "arctic", "accent" => "#ffcc00"})
      {:ok, _view, html} = live(conn, ~p"/shop")
      assert html =~ "--sh-accent: #ffcc00"
    end

    test "a server that does not answer shows offline", %{conn: conn, server: server} do
      Req.Test.stub(HllConditionalActions.Crcon, &Plug.Conn.send_resp(&1, 500, "down"))
      all_sections()
      {:ok, view, _html} = live(conn, ~p"/shop")
      render_async(view)
      assert has_element?(view, "#server-#{server.id}")
      refute has_element?(view, "#hero-live")
    end
  end

  describe "signing in" do
    test "the sign in page offers email and password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/shop/login")
      assert has_element?(view, "#shop-login-form")
    end

    test "the sign up form shows how strong the password is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/shop/register")

      view
      |> form("#shop-register-form", %{"customer" => %{"password" => "trincheira-de-carentan"}})
      |> render_change()

      assert has_element?(view, "#register-strength")
    end

    test "a sign in can land on a shop page", %{conn: conn} do
      {_conn, _customer} = as_customer(conn)

      conn =
        post(conn, ~p"/shop/login", %{
          "customer" => %{
            "email" => "ko@example.com",
            "password" => "secret1234",
            "return_to" => "/shop/account"
          }
        })

      assert redirected_to(conn) == "/shop/account"
    end

    test "a sign in never lands outside the shop", %{conn: conn} do
      {_conn, _customer} = as_customer(conn)

      conn =
        post(conn, ~p"/shop/login", %{
          "customer" => %{
            "email" => "ko@example.com",
            "password" => "secret1234",
            "return_to" => "https://evil.example.com"
          }
        })

      assert redirected_to(conn) == "/shop"
    end

    test "the forgot password page waits before sending again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/shop/reset")

      view
      |> form("#forgot-form", %{"reset" => %{"email" => "nobody@example.com"}})
      |> render_submit()

      assert has_element?(view, "#reset-sent")
      assert has_element?(view, "#resend-link[disabled]")
    end

    test "a new password from the link shows it changed", %{conn: conn} do
      {_conn, customer} = as_customer(conn)
      {token, row} = HllConditionalActions.VipShop.CustomerToken.build(customer.id, "reset")
      Repo.insert!(row)

      {:ok, view, _html} = live(conn, ~p"/shop/reset/#{token}")

      view
      |> form("#reset-form", %{
        "customer" => %{
          "password" => "nova-senha-1234",
          "password_confirmation" => "nova-senha-1234"
        }
      })
      |> render_submit()

      assert has_element?(view, "#password-changed")
      assert {:ok, _customer} = VipShop.authenticate_customer("ko@example.com", "nova-senha-1234")
    end
  end

  describe "checkout" do
    test "a gift is picked by name and carries a message", %{conn: conn, package: package} do
      stub_crcon([
        %{
          "player_id" => "76561198071139524",
          "names" => [%{"name" => "Santos"}],
          "last_seen_timestamp_ms" => System.system_time(:millisecond),
          "current_playtime_seconds" => 120
        }
      ])

      Req.Test.stub(Payments, fn conn ->
        Req.Test.json(conn, %{"id" => "cs_2", "url" => "https://checkout.stripe.com/c/cs_2"})
      end)

      {conn, _customer} = as_customer(conn)
      {:ok, view, _html} = live(conn, ~p"/shop/buy/#{package.id}")

      assert has_element?(view, "#gift-picker")

      view
      |> form("#checkout-form", %{"q" => "santos"})
      |> render_change(%{"_target" => ["q"]})

      html =
        view
        |> form("#checkout-form", %{"gift" => "76561198071139524"})
        |> render_change(%{"_target" => ["gift"]})

      assert html =~ "Santos"

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/cs_2"}}} =
               view
               |> form("#checkout-form", %{"message" => "Tamo junto, Santos!"})
               |> render_submit()

      order = VipShop.get_order_by_ref("stripe", "cs_2")
      assert order.gift
      assert order.player_id == "76561198071139524"
      assert %OrderNote{message: "Tamo junto, Santos!"} = Storefront.order_note(order.id)
    end

    test "a coupon can be removed", %{conn: conn, package: package} do
      {:ok, _coupon} =
        VipShop.save_coupon(%Coupon{}, %{"code" => "OUTONO15", "kind" => "percent", "value" => 15})

      {conn, customer} = as_customer(conn)
      {:ok, _link} = VipShop.link_player(customer, "7656", "Kowalski")
      {:ok, view, _html} = live(conn, ~p"/shop/buy/#{package.id}")

      view |> form("#coupon-form", %{"code" => "outono15"}) |> render_submit()
      assert has_element?(view, "#coupon-applied")
      assert render(view) =~ VipShop.format_money(4990 - 748, "BRL")

      view |> element("#checkout-coupon button", "Remove") |> render_click()
      refute has_element?(view, "#coupon-applied")
    end

    test "the summary says until when the VIP will run", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Kowalski")
      {:ok, view, _html} = live(conn, ~p"/shop/buy/#{package.id}")

      until = DateTime.add(DateTime.utc_now(), 90 * 86_400)
      assert render(view) =~ "#{until.year}"
      assert has_element?(view, "input[name=player][value='#{link.id}'][checked]")
    end
  end

  describe "the order page" do
    test "shows each server's delivery and the receipt", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Kowalski")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      order
      |> Ecto.Changeset.change(status: "fulfilled", paid_at: DateTime.utc_now(:second))
      |> Repo.update!()

      [server] = VipShop.get_package!(package.id).servers

      Repo.insert!(%Grant{
        order_id: order.id,
        server_id: server.id,
        server_name: server.name,
        status: "granted",
        expires_at: DateTime.add(DateTime.utc_now(:second), 90 * 86_400)
      })

      {:ok, view, _html} = live(conn, ~p"/shop/orders/#{order.id}")
      assert has_element?(view, "#order-status")
      assert has_element?(view, "#delivery-#{server.id}")
      assert has_element?(view, "#download-receipt")
      assert has_element?(view, "#receipt-player-id", "7656")
    end

    test "the reminder switch saves the customer's choice", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Kowalski")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      {:ok, view, _html} = live(conn, ~p"/shop/orders/#{order.id}")
      view |> element("#reminder-switch") |> render_click()
      refute Storefront.wants_email?(customer.id, :expiry_reminders)
    end
  end

  describe "the account" do
    test "lists orders and saves the email notices", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Kowalski")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      {:ok, view, _html} = live(conn, ~p"/shop/account")
      assert has_element?(view, "#order-#{order.id}")
      assert has_element?(view, "#player-#{link.id}")

      view
      |> form("#preferences-form", %{"expiry_reminders" => "true", "receipts" => "false"})
      |> render_change()

      refute Storefront.wants_email?(customer.id, :receipts)
      assert Storefront.wants_email?(customer.id, :expiry_reminders)
    end

    test "changing the email asks for the password", %{conn: conn} do
      {conn, customer} = as_customer(conn)
      {:ok, view, _html} = live(conn, ~p"/shop/account")

      view |> element("#edit-email") |> render_click()

      view
      |> form("#email-form", %{
        "account" => %{"email" => "new@example.com", "password" => "wrong"}
      })
      |> render_submit()

      assert VipShop.get_customer(customer.id).email == "ko@example.com"

      view
      |> form("#email-form", %{
        "account" => %{"email" => "new@example.com", "password" => "secret1234"}
      })
      |> render_submit()

      assert VipShop.get_customer(customer.id).email == "new@example.com"
    end

    test "Discord cannot be disconnected when it is the only way in" do
      customer = %HllConditionalActions.VipShop.Customer{discord_id: "1", hashed_password: nil}
      assert {:error, :only_sign_in} = Storefront.disconnect_discord(customer)
    end
  end

  describe "storefront data" do
    test "a VIP bought now adds to the one the player has", %{package: package} do
      in_ten_days = DateTime.add(DateTime.utc_now(:second), 10 * 86_400)
      until = Storefront.valid_until(package, in_ten_days, "extend")
      assert DateTime.diff(until, in_ten_days, :day) == 90

      fresh = Storefront.valid_until(package, in_ten_days, "replace")
      assert_in_delta DateTime.diff(fresh, DateTime.utc_now(), :day), 90, 1
    end

    test "the ways to pay follow the providers" do
      assert Storefront.payment_methods([%{provider: "stripe"}]) == [:card]

      assert Storefront.payment_methods([%{provider: "mercado_pago"}, %{provider: "stripe"}]) ==
               [:pix, :card, :boleto]
    end

    test "a gift message waits for the delivery and is sent in the game", %{package: package} do
      {:ok, customer} =
        VipShop.register_customer(%{
          "name" => "Ko",
          "email" => "ko2@example.com",
          "password" => "secret1234"
        })

      gift = %{player_id: "7656", player_name: "Santos", gift: true}
      {:ok, order} = VipShop.create_order(customer, package, gift, "stripe")
      {:ok, _note} = Storefront.put_order_note(order, "Tamo junto!")

      assert_enqueued(
        worker: HllConditionalActions.Workers.DeliverGiftMessage,
        args: %{order_id: order.id}
      )

      assert {:snooze, _seconds} =
               perform_job(HllConditionalActions.Workers.DeliverGiftMessage, %{
                 order_id: order.id
               })
    end
  end
end
