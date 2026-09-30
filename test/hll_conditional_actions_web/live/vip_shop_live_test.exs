defmodule HllConditionalActionsWeb.VipShopLiveTest do
  # Not async: the shop tests share the payment providers' rows, and inserting
  # them from parallel sandboxes deadlocks.
  use HllConditionalActionsWeb.ConnCase, async: false
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures
  import Phoenix.LiveViewTest

  alias HllConditionalActions.VipShop
  alias HllConditionalActions.VipShop.{Design, Order, Package, Payments}

  setup %{conn: conn} do
    server = server_fixture(%{name: "Caveiras #1"})

    {:ok, package} =
      VipShop.save_package(%Package{}, %{
        "name" => "VIP 30",
        "price" => "19.90",
        "currency" => "BRL",
        "duration_days" => 30,
        "server_ids" => [server.id]
      })

    {:ok, _stripe} =
      VipShop.update_provider("stripe", %{
        "enabled" => true,
        "credentials" => %{"secret_key" => "sk_test", "webhook_secret" => "whsec"}
      })

    %{conn: init_test_session(conn, %{}), server: server, package: package}
  end

  defp as_customer(conn) do
    {:ok, customer} =
      VipShop.register_customer(%{
        "name" => "Ana",
        "email" => "ana@example.com",
        "password" => "secret1234"
      })

    {Plug.Conn.put_session(conn, :shop_customer_id, customer.id), customer}
  end

  describe "the public shop" do
    test "lists packages to anyone", %{conn: conn, package: package} do
      {:ok, view, _html} = live(conn, ~p"/shop")
      assert has_element?(view, "#package-#{package.id}")
    end

    test "is closed when no server installed it", %{conn: conn, server: server} do
      :ok = HllConditionalActions.Features.uninstall(server.id, :vip_shop)
      assert conn |> get(~p"/shop") |> response(404)
    end

    test "says it is coming soon while the admin keeps it closed", %{conn: conn} do
      {:ok, _settings} = VipShop.set_closed(true)

      page = conn |> get(~p"/shop") |> html_response(503) |> LazyHTML.from_document()
      assert page |> LazyHTML.query("#shop-closed") |> Enum.count() == 1
      assert page |> LazyHTML.query("[id^=package-]") |> Enum.empty?()
    end

    test "sends visitors to sign in before buying", %{conn: conn, package: package} do
      assert {:error, {:redirect, %{to: "/shop/login"}}} = live(conn, ~p"/shop/buy/#{package.id}")
    end

    test "signs a customer in with email and password", %{conn: conn} do
      {:ok, _customer} =
        VipShop.register_customer(%{
          "name" => "Ana",
          "email" => "ana@example.com",
          "password" => "secret1234"
        })

      conn =
        post(conn, ~p"/shop/login", %{
          "customer" => %{"email" => "ana@example.com", "password" => "secret1234"}
        })

      assert redirected_to(conn) == "/shop"
      assert get_session(conn, :shop_customer_id)
    end

    test "customer session is not an admin session", %{conn: conn} do
      {conn, _customer} = as_customer(conn)
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/vip-shop")
    end

    test "checkout opens the provider's page for a linked player", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Ana")

      Req.Test.stub(Payments, fn conn ->
        Req.Test.json(conn, %{"id" => "cs_1", "url" => "https://checkout.stripe.com/c/cs_1"})
      end)

      {:ok, view, _html} = live(conn, ~p"/shop/buy/#{package.id}")

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/cs_1"}}} =
               view
               |> form("#checkout-form", %{"player" => link.id, "provider" => "stripe"})
               |> render_submit()

      assert %Order{status: "pending", provider_ref: "cs_1"} =
               VipShop.get_order_by_ref("stripe", "cs_1")
    end
  end

  describe "the Stripe webhook" do
    test "marks the order paid when the signature is right", %{conn: conn, package: package} do
      {_conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Ana")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")
      {:ok, _order} = VipShop.put_provider_ref(order, "cs_2")

      body =
        Jason.encode!(%{
          "type" => "checkout.session.completed",
          "data" => %{"object" => %{"id" => "cs_2", "payment_status" => "paid"}}
        })

      now = System.system_time(:second)
      signature = "t=#{now},v1=#{Payments.hmac_hex("whsec", "#{now}.#{body}")}"

      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", signature)
        |> post("/webhooks/stripe", body)

      assert response.status == 200
      assert VipShop.get_order(order.id).status == "paid"
    end

    test "refuses a bad signature", %{conn: _conn} do
      response =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=1,v1=bad")
        |> post("/webhooks/stripe", ~s({"type":"x"}))

      assert response.status == 400
    end

    test "an unknown provider has no webhook" do
      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/webhooks/paypal", "{}")
             |> response(404)
    end
  end

  describe "the admin" do
    setup %{conn: conn} do
      %{conn: Plug.Conn.put_session(conn, :user_id, user_fixture().id)}
    end

    test "lists packages and the purchases page opens", %{conn: conn, package: package} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop?guide=skip")
      assert has_element?(view, "#package-#{package.id}")
      assert has_element?(view, "#overview-kpis")

      {:ok, view, _html} = live(conn, ~p"/vip-shop/packages/#{package.id}/edit")
      assert has_element?(view, "#packages #package-#{package.id}")
      assert has_element?(view, "#package-form")
      assert has_element?(view, "#package-preview")

      {:ok, _view, _html} = live(conn, ~p"/vip-shop/purchases")
    end

    test "customises the public page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings")

      view
      |> form("#page-form", %{
        "settings" => %{
          "shop_title" => "Caveiras VIP",
          "social_links" => %{"discord" => "https://discord.gg/abc"}
        }
      })
      |> render_submit()

      settings = VipShop.settings()
      assert settings.shop_title == "Caveiras VIP"
      assert settings.social_links == %{"discord" => "https://discord.gg/abc"}

      {:ok, _view, html} = live(build_conn(), ~p"/shop")
      assert html =~ "Caveiras VIP"
      assert html =~ "https://discord.gg/abc"
    end

    test "every settings section opens", %{conn: conn} do
      for section <- ~w(setup design payments login email general) do
        assert {:ok, _view, _html} = live(conn, ~p"/vip-shop/settings/#{section}")
      end
    end
  end

  describe "new pages" do
    test "the order page follows the purchase", %{conn: conn, package: package} do
      {conn, customer} = as_customer(conn)
      {:ok, link} = VipShop.link_player(customer, "7656", "Ana")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      {:ok, view, _html} = live(conn, ~p"/shop/orders/#{order.id}")
      assert has_element?(view, "#order-status")
    end

    test "someone else's order is not shown", %{conn: conn, package: package} do
      {:ok, other} =
        VipShop.register_customer(%{
          "name" => "Bo",
          "email" => "bo@example.com",
          "password" => "secret1234"
        })

      {:ok, link} = VipShop.link_player(other, "1", "Bo")
      {:ok, order} = VipShop.create_order(other, package, link, "stripe")
      {conn, _customer} = as_customer(conn)

      assert {:error, {:live_redirect, %{to: "/shop/account"}}} =
               live(conn, ~p"/shop/orders/#{order.id}")
    end

    test "asking for a password reset always says the same", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/shop/reset")

      view
      |> form("#forgot-form", %{"reset" => %{"email" => "nobody@example.com"}})
      |> render_submit()

      assert has_element?(view, "#reset-sent")
    end

    test "the checkout applies a coupon", %{conn: conn, package: package} do
      {:ok, _coupon} =
        VipShop.save_coupon(%HllConditionalActions.VipShop.Coupon{}, %{
          "code" => "OFF10",
          "kind" => "percent",
          "value" => 10
        })

      {conn, customer} = as_customer(conn)
      {:ok, _link} = VipShop.link_player(customer, "7656", "Ana")

      {:ok, view, _html} = live(conn, ~p"/shop/buy/#{package.id}")
      html = view |> form("#coupon-form", %{"code" => "off10"}) |> render_submit()
      assert html =~ VipShop.format_money(1791, "BRL")
    end
  end

  describe "payment health" do
    setup %{conn: conn} do
      %{conn: Plug.Conn.put_session(conn, :user_id, user_fixture().id)}
    end

    defp stripe_webhook(body, secret \\ "whsec") do
      now = System.system_time(:second)

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "stripe-signature",
        "t=#{now},v1=#{Payments.hmac_hex(secret, "#{now}.#{body}")}"
      )
      |> post("/webhooks/stripe", body)
    end

    test "webhooks leave a trace on the provider, accepted or refused" do
      assert stripe_webhook(
               ~s({"type":"checkout.session.expired","data":{"object":{"id":"cs_x"}}})
             ).status ==
               200

      provider = VipShop.get_provider("stripe")
      assert provider.last_webhook_event == "checkout.session.expired"
      assert provider.last_webhook_at

      assert stripe_webhook(~s({"type":"x"}), "wrong").status == 400
      assert VipShop.get_provider("stripe").last_webhook_error == "bad signature"
    end

    test "saving a payment method tries its keys", %{conn: conn} do
      Req.Test.stub(Payments, fn conn ->
        assert conn.request_path == "/v1/checkout/sessions"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"message":"Invalid API Key provided"}}))
      end)

      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/payments?provider=stripe")

      html =
        view
        |> form("#provider-form-stripe", %{
          "provider" => %{"credentials" => %{"secret_key" => "sk_test_bad"}}
        })
        |> render_submit()

      assert html =~ "Invalid API Key provided"
      assert VipShop.get_provider("stripe").check_error == "Invalid API Key provided"

      Req.Test.stub(Payments, &Req.Test.json(&1, %{"data" => []}))
      view |> element("#check-stripe") |> render_click()

      provider = VipShop.get_provider("stripe")
      assert provider.checked_at
      refute provider.check_error
      assert has_element?(view, "#health-stripe", "Key valid")
    end

    test "Stripe's mode follows its key" do
      {:ok, provider} =
        VipShop.update_provider("stripe", %{
          "mode" => "test",
          "credentials" => %{"secret_key" => "rk_live_1"}
        })

      assert provider.mode == "live"
    end

    test "a test purchase is paid but never delivered nor counted", %{conn: conn} do
      Req.Test.stub(Payments, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cs_test_1",
          "url" => "https://checkout.stripe.com/c/cs_test_1"
        })
      end)

      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/payments")

      assert {:error, {:redirect, %{to: "https://checkout.stripe.com/c/cs_test_1"}}} =
               view |> element("#test-purchase-stripe") |> render_click()

      order = VipShop.get_order_by_ref("stripe", "cs_test_1")
      assert %Order{test: true, amount_cents: 100, customer_id: nil} = order

      body =
        Jason.encode!(%{
          "type" => "checkout.session.completed",
          "data" => %{"object" => %{"id" => "cs_test_1", "payment_status" => "paid"}}
        })

      assert stripe_webhook(body).status == 200
      assert VipShop.get_order(order.id).status == "paid"
      refute_enqueued(worker: HllConditionalActions.Workers.FulfillVipOrder)
      assert VipShop.totals().orders == 0
      assert Enum.find(VipShop.setup_steps(), &(&1.key == :test_purchase)).done

      {:ok, _view, html} = live(conn, ~p"/vip-shop/settings/payments")
      assert html =~ "Paid"
    end

    test "the shop's first page shows what is left to open it", %{conn: conn, package: package} do
      assert {:error, {:live_redirect, %{to: "/vip-shop/settings/setup"}}} =
               live(conn, ~p"/vip-shop")

      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/setup")
      assert has_element?(view, "#shop-setup")
      # Done: the package step can be reviewed; the payment step is open.
      assert has_element?(view, "#setup-package a", "Revisit")
      assert has_element?(view, "#setup-payment #setup-configure")
      assert package.active
    end

    test "the e-mail preview follows the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/email")

      html =
        view
        |> form("#template-form", %{
          "template" => %{"subject" => "Hi {name}", "body" => "Order {order_id}"}
        })
        |> render_change()

      assert html =~ "1042"
      assert has_element?(view, "#template-preview", "Order 1042")
    end
  end

  describe "new admin pages" do
    setup %{conn: conn} do
      %{conn: Plug.Conn.put_session(conn, :user_id, user_fixture().id)}
    end

    test "coupons can be created", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/coupons/new")

      view
      |> form("#coupon-form", %{
        "coupon" => %{"code" => "event", "kind" => "percent", "value" => "15"}
      })
      |> render_submit()

      assert has_element?(view, "#coupons")
      assert [%{code: "EVENT"}] = VipShop.list_coupons()
    end

    test "the design tab saves", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/design")
      view |> form("#design-form", %{"design" => %{"theme" => "arctic"}}) |> render_submit()

      assert Design.get(VipShop.settings().design)["theme"] ==
               "arctic"
    end

    test "an admin gives VIP by player ID", %{conn: conn, package: package} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/purchases/grant")
      assert has_element?(view, "#grant-button[aria-expanded=true]")

      server_id = hd(package.servers).id

      view
      |> form("#grant-form", %{
        "q" => "76561198000000001",
        "days" => "90",
        "server_ids" => [server_id],
        "reason" => "1st place"
      })
      |> render_submit()

      assert [%{provider: "manual", player_id: "76561198000000001"} = order] =
               VipShop.recent_orders()

      assert order.duration_days == 90
      assert order.server_ids == [server_id]
      assert order.reason == "1st place"
    end
  end

  describe "admin fidelity" do
    setup %{conn: conn} do
      %{conn: Plug.Conn.put_session(conn, :user_id, user_fixture().id)}
    end

    defp order_fixture(package, attrs) do
      {:ok, customer} =
        VipShop.register_customer(%{
          "name" => "Lima",
          "email" => "lima#{System.unique_integer([:positive])}@example.com",
          "password" => "secret1234"
        })

      {:ok, link} = VipShop.link_player(customer, "76561190000000009", "Santos")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      order
      |> Ecto.Changeset.change(Map.merge(%{paid_at: DateTime.utc_now(:second)}, attrs))
      |> HllConditionalActions.Repo.update!()
    end

    test "purchases filter by status and open a row with its delivery", %{
      conn: conn,
      package: package,
      server: server
    } do
      paid = order_fixture(package, %{status: "partial"})
      _waiting = order_fixture(package, %{status: "pending", paid_at: nil})

      HllConditionalActions.Repo.insert!(%HllConditionalActions.VipShop.Grant{
        order_id: paid.id,
        server_id: server.id,
        server_name: server.name,
        status: "failed"
      })

      {:ok, view, _html} = live(conn, ~p"/vip-shop/purchases")
      assert has_element?(view, "#bucket-all", "2")
      # The order waiting for a server opens by itself, with its retry.
      assert has_element?(view, "[id^='grant-#{paid.id}-']")
      assert has_element?(view, "#purchase-#{paid.id} button", "Try again")

      view |> element("#bucket-pending") |> render_click()
      refute has_element?(view, "#purchase-#{paid.id}")
    end

    test "a coupon is switched off from the list", %{conn: conn} do
      {:ok, coupon} =
        VipShop.save_coupon(%HllConditionalActions.VipShop.Coupon{}, %{
          "code" => "OUTONO15",
          "kind" => "percent",
          "value" => 15
        })

      {:ok, view, _html} = live(conn, ~p"/vip-shop/coupons")
      assert has_element?(view, "#coupon-#{coupon.id}[aria-selected=true]")

      view |> element("#coupon-active-#{coupon.id}") |> render_click()
      refute VipShop.get_coupon!(coupon.id).active
    end

    test "the storefront keeps a draft until it is published", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/design")

      view
      |> form("#design-form", %{"design" => %{"theme" => "desert"}})
      |> render_change()

      assert has_element?(view, "#unpublished")

      assert Design.get(VipShop.settings().design)["theme"] ==
               "tactical"

      view |> form("#design-form") |> render_submit()
      refute has_element?(view, "#unpublished")
    end

    test "the guide closes and opens the shop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/vip-shop/settings/setup")
      view |> element("#close-shop") |> render_click()
      refute VipShop.open?()
      assert has_element?(view, "#open-shop[disabled]")
    end
  end
end
