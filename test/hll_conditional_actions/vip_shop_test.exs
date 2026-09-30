defmodule HllConditionalActions.VipShopTest do
  use HllConditionalActions.DataCase, async: true
  use Oban.Testing, repo: HllConditionalActions.Repo

  import HllConditionalActions.Fixtures
  import Swoosh.TestAssertions

  alias HllConditionalActions.Attention
  alias HllConditionalActions.VipShop

  alias HllConditionalActions.VipShop.{
    Coupon,
    Design,
    Emails,
    Grant,
    Order,
    PaymentProvider,
    Payments,
    Settings,
    Stats,
    Storefront
  }

  alias HllConditionalActions.Workers.{FulfillVipOrder, SendShopEmail}

  doctest VipShop
  doctest Emails
  doctest PaymentProvider
  doctest Payments
  doctest Payments.Stripe
  doctest Payments.MercadoPago
  doctest Payments.Dodo
  doctest HllConditionalActions.VipShop.Package
  doctest HllConditionalActions.VipShop.Coupon
  doctest HllConditionalActions.VipShop.Design

  setup do
    a = server_fixture(%{name: "A"})
    b = server_fixture(%{name: "B"})
    without = server_fixture(%{name: "No shop", features: []})

    {:ok, _stripe} =
      VipShop.update_provider("stripe", %{
        "enabled" => true,
        "credentials" => %{"secret_key" => "sk_test", "webhook_secret" => "whsec"}
      })

    %{a: a, b: b, without: without}
  end

  defp package_fixture(servers, attrs \\ %{}) do
    {:ok, package} =
      VipShop.save_package(
        %HllConditionalActions.VipShop.Package{},
        Map.merge(
          %{
            "name" => "VIP 30",
            "price" => "19.90",
            "currency" => "BRL",
            "duration_days" => 30,
            "server_ids" => Enum.map(servers, & &1.id)
          },
          attrs
        )
      )

    package
  end

  defp customer_with_player do
    {:ok, customer} =
      VipShop.register_customer(%{
        "name" => "Ana",
        "email" => "ana@example.com",
        "password" => "secret1234"
      })

    {:ok, link} = VipShop.link_player(customer, "76561190000000001", "Ana")
    {customer, link}
  end

  describe "packages" do
    test "only target servers that installed the shop", %{a: a, without: without} do
      package = package_fixture([a, without])

      assert Enum.map(package.servers, & &1.id) == [a.id]
      assert package.price_cents == 1990
    end

    test "need at least one server", %{without: without} do
      assert {:error, changeset} =
               VipShop.save_package(%HllConditionalActions.VipShop.Package{}, %{
                 "name" => "X",
                 "price" => "1",
                 "currency" => "BRL",
                 "server_ids" => [without.id]
               })

      assert %{servers: [_error]} = errors_on(changeset)
    end
  end

  describe "customers" do
    test "register, then sign in with the same password" do
      {customer, _link} = customer_with_player()

      assert {:ok, %{id: id}} = VipShop.authenticate_customer("ANA@example.com ", "secret1234")
      assert id == customer.id
      assert :error = VipShop.authenticate_customer("ana@example.com", "wrong")
      assert_enqueued(worker: SendShopEmail, args: %{"template" => "welcome"})
    end

    test "a Discord sign in reuses the account with the same verified email" do
      {customer, _link} = customer_with_player()

      assert {:ok, same} =
               VipShop.customer_from_discord(%{
                 "id" => "42",
                 "username" => "ana",
                 "email" => "ana@example.com",
                 "verified" => true
               })

      assert same.id == customer.id
      assert same.discord_id == "42"
    end
  end

  describe "a purchase" do
    test "is granted on every server of the package once paid", %{a: a, b: b} do
      package = package_fixture([a, b])
      {customer, link} = customer_with_player()

      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        case conn.request_path do
          "/api/get_vip_ids" -> Req.Test.json(conn, %{"result" => [], "failed" => false})
          "/api/add_vip" -> Req.Test.json(conn, %{"result" => true, "failed" => false})
        end
      end)

      assert {:ok, order} = VipShop.create_order(customer, package, link, "stripe")
      assert order.status == "pending"

      {:ok, order} = VipShop.put_provider_ref(order, "cs_1")

      assert {:ok, %Order{status: "paid"}} =
               VipShop.apply_outcome("stripe", {:paid, {:provider_ref, "cs_1"}})

      # Reported twice (webhook and return page): queued only once.
      assert {:ok, _order} = VipShop.apply_outcome("stripe", {:paid, {:provider_ref, "cs_1"}})
      assert [_job] = all_enqueued(worker: FulfillVipOrder)

      assert :ok = perform_job(FulfillVipOrder, %{order_id: order.id})

      order = VipShop.get_order(order.id)
      assert order.status == "fulfilled"
      assert order.grants |> Enum.map(& &1.server_name) |> Enum.sort() == ["A", "B"]
      assert Enum.all?(order.grants, &(&1.status == "granted"))
      assert_enqueued(worker: SendShopEmail, args: %{"template" => "purchase"})
    end

    test "a failing server leaves the order partial", %{a: a, b: b} do
      package = package_fixture([a, b])
      {customer, link} = customer_with_player()
      # Both servers share the fixture's address; the second grant fails.
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        case conn.request_path do
          "/api/get_vip_ids" ->
            Req.Test.json(conn, %{"result" => [], "failed" => false})

          "/api/add_vip" ->
            Process.put(:calls, Process.get(:calls, 0) + 1)

            if Process.get(:calls) == 2,
              do:
                conn
                |> Plug.Conn.put_status(500)
                |> Req.Test.json(%{"error" => "boom", "failed" => true}),
              else: Req.Test.json(conn, %{"result" => true, "failed" => false})
        end
      end)

      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")
      {:ok, _paid} = VipShop.mark_paid(order)
      {:ok, order} = order.id |> VipShop.get_order() |> VipShop.fulfill()

      assert order.status == "partial"
      assert Enum.count(order.grants, &(&1.status == "failed")) == 1
    end

    test "extending adds the days to the VIP that is left", %{a: a} do
      {customer, link} = customer_with_player()
      package = package_fixture([a])
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")
      left = DateTime.add(DateTime.utc_now(:second), 10 * 86_400, :second)

      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{
          "result" => [
            %{"player_id" => link.player_id, "vip_expiration" => DateTime.to_iso8601(left)}
          ],
          "failed" => false
        })
      end)

      extended = VipShop.expiration(order, a, "extend")
      replaced = VipShop.expiration(order, a, "replace")

      assert DateTime.diff(extended, left, :day) == 30
      assert DateTime.diff(replaced, DateTime.utc_now(), :day) in 29..30
    end

    test "cannot use somebody else's player or a disabled provider", %{a: a} do
      package = package_fixture([a])
      {customer, link} = customer_with_player()
      other = %{link | customer_id: customer.id + 1}

      assert {:error, :not_your_player} = VipShop.create_order(customer, package, other, "stripe")

      assert {:error, :provider_disabled} =
               VipShop.create_order(customer, package, link, "dodo")
    end
  end

  describe "providers" do
    test "cannot be enabled without every credential" do
      assert {:error, changeset} = VipShop.update_provider("dodo", %{"enabled" => true})
      assert %{enabled: [_error]} = errors_on(changeset)
    end

    test "blank credentials keep the stored ones" do
      {:ok, provider} =
        VipShop.update_provider("stripe", %{"credentials" => %{"secret_key" => ""}})

      assert provider.credentials["secret_key"] == "sk_test"
    end

    test "stripe checkout returns the session page" do
      Req.Test.stub(Payments, fn conn ->
        assert conn.request_path == "/v1/checkout/sessions"
        Req.Test.json(conn, %{"id" => "cs_9", "url" => "https://checkout.stripe.com/c/cs_9"})
      end)

      provider = VipShop.get_provider("stripe")

      order = %Order{
        id: 7,
        package_name: "VIP",
        player_id: "1",
        amount_cents: 990,
        currency: "BRL"
      }

      assert {:ok, %{url: "https://checkout.stripe.com/c/cs_9", ref: "cs_9"}} =
               Payments.Stripe.checkout(provider, order, %{
                 success: "https://x/s",
                 cancel: "https://x/c"
               })
    end

    test "a mercado pago notification is confirmed with the API before anything is marked" do
      {:ok, provider} =
        VipShop.update_provider("mercado_pago", %{
          "enabled" => true,
          "credentials" => %{"access_token" => "t", "webhook_secret" => ""}
        })

      Req.Test.stub(Payments, fn conn ->
        assert conn.request_path == "/v1/payments/55"
        Req.Test.json(conn, %{"status" => "approved", "external_reference" => "12"})
      end)

      assert {:ok, {:paid, {:order_id, "12"}}} =
               Payments.MercadoPago.handle_webhook(provider, %{}, %{
                 "type" => "payment",
                 "data" => %{"id" => "55"}
               })
    end

    test "a mercado pago notification for an unknown payment is ignored" do
      {:ok, provider} =
        VipShop.update_provider("mercado_pago", %{
          "enabled" => true,
          "credentials" => %{"access_token" => "t", "webhook_secret" => ""}
        })

      Req.Test.stub(Payments, &Plug.Conn.send_resp(&1, 404, "{}"))

      assert {:ok, :ignore} =
               Payments.MercadoPago.handle_webhook(provider, %{}, %{
                 "type" => "payment",
                 "data" => %{"id" => "123456"}
               })
    end

    test "dodo checkout creates its product once and charges the order's amount" do
      {:ok, provider} =
        VipShop.update_provider("dodo", %{
          "enabled" => true,
          "credentials" => %{"api_key" => "dk", "webhook_secret" => "whsec_a2V5"}
        })

      parent = self()

      Req.Test.stub(Payments, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {conn.request_path, Jason.decode!(body)})

        case conn.request_path do
          "/products" ->
            Req.Test.json(conn, %{"product_id" => "pdt_1"})

          "/checkouts" ->
            Req.Test.json(conn, %{"session_id" => "cks_1", "checkout_url" => "https://pay/cks_1"})
        end
      end)

      order = %Order{
        id: 7,
        package_name: "VIP",
        player_id: "1",
        amount_cents: 990,
        currency: "BRL"
      }

      urls = %{success: "https://x/s", cancel: "https://x/c"}

      assert {:ok, %{url: "https://pay/cks_1", ref: "cks_1"}} =
               Payments.Dodo.checkout(provider, order, urls)

      assert_received {"/products",
                       %{"price" => %{"currency" => "BRL", "pay_what_you_want" => true}}}

      assert_received {"/checkouts",
                       %{
                         "product_cart" => [%{"product_id" => "pdt_1", "amount" => 990}],
                         "metadata" => %{"order_id" => "7"}
                       }}

      provider = VipShop.get_provider("dodo")
      assert provider.credentials["product:test:BRL"] == "pdt_1"

      assert {:ok, _} = Payments.Dodo.checkout(provider, order, urls)
      refute_received {"/products", _body}

      # A new key is another account: the product is made again there.
      {:ok, provider} =
        VipShop.update_provider("dodo", %{"credentials" => %{"api_key" => "other"}})

      refute Map.has_key?(provider.credentials, "product:test:BRL")
    end

    test "a signed dodo webhook marks the order in its metadata" do
      {:ok, provider} =
        VipShop.update_provider("dodo", %{
          "enabled" => true,
          "credentials" => %{
            "api_key" => "dk",
            "webhook_secret" => "whsec_" <> Base.encode64("key")
          }
        })

      body =
        Jason.encode!(%{
          "type" => "payment.succeeded",
          "data" => %{"status" => "succeeded", "metadata" => %{"order_id" => "12"}}
        })

      now = to_string(System.system_time(:second))
      sig = :crypto.mac(:hmac, :sha256, "key", "msg_1.#{now}.#{body}") |> Base.encode64()

      headers = %{
        "webhook-id" => "msg_1",
        "webhook-timestamp" => now,
        "webhook-signature" => "v1,#{sig}"
      }

      assert {:ok, {:paid, {:order_id, "12"}}} =
               Payments.Dodo.handle_webhook(provider, %{raw_body: body, headers: headers}, %{})

      assert {:error, "bad signature"} =
               Payments.Dodo.handle_webhook(
                 provider,
                 %{raw_body: body <> " ", headers: headers},
                 %{}
               )
    end

    test "the dodo return page is confirmed with the API" do
      {:ok, provider} =
        VipShop.update_provider("dodo", %{
          "enabled" => true,
          "credentials" => %{"api_key" => "dk", "webhook_secret" => "whsec_a2V5"}
        })

      Req.Test.stub(Payments, fn conn ->
        assert conn.request_path == "/payments/pay_1"
        Req.Test.json(conn, %{"status" => "succeeded", "metadata" => %{"order_id" => "12"}})
      end)

      assert {:ok, {:paid, {:order_id, "12"}}} =
               Payments.Dodo.confirm(provider, %{"payment_id" => "pay_1", "status" => "succeeded"})
    end
  end

  describe "email" do
    test "templates fall back to the default and can be customised" do
      settings = %Settings{email_templates: %{"welcome" => %{"subject" => "Oi {name}"}}}

      assert Emails.template(settings, "welcome").subject == "Oi {name}"
      assert Emails.template(settings, "purchase").subject =~ "{order_id}"
    end

    test "is sent through the configured service" do
      {:ok, _settings} =
        VipShop.update_settings(:email, %{
          "email_provider" => "smtp",
          "smtp_host" => "smtp.example.com",
          "mail_from_address" => "shop@example.com"
        })

      assert :ok =
               perform_job(SendShopEmail, %{
                 to: "ana@example.com",
                 template: "welcome",
                 vars: %{"name" => "Ana"}
               })

      assert_email_sent(to: "ana@example.com")
    end
  end

  describe "password reset" do
    test "a link sets a new password once" do
      {customer, _link} = customer_with_player()
      parent = self()

      :ok =
        VipShop.request_password_reset("ANA@example.com", fn token ->
          send(parent, {:token, token})
          "https://x/#{token}"
        end)

      assert_receive {:token, token}
      assert_enqueued(worker: SendShopEmail, args: %{"template" => "reset"})

      assert {:ok, _customer} =
               VipShop.reset_password(token, %{
                 "password" => "newpass1234",
                 "password_confirmation" => "newpass1234"
               })

      assert {:ok, %{id: id}} = VipShop.authenticate_customer("ana@example.com", "newpass1234")
      assert id == customer.id

      assert {:error, :invalid_token} =
               VipShop.reset_password(token, %{"password" => "another1234"})
    end

    test "an unknown email is answered the same and sends nothing" do
      assert :ok =
               VipShop.request_password_reset("nobody@example.com", fn _token ->
                 flunk("no link")
               end)

      refute_enqueued(worker: SendShopEmail, args: %{"template" => "reset"})
    end
  end

  describe "coupons, gifts and manual grants" do
    test "a coupon lowers the price and counts a use when paid", %{a: a} do
      package = package_fixture([a])
      {customer, link} = customer_with_player()

      {:ok, coupon} =
        VipShop.save_coupon(%Coupon{}, %{
          "code" => "caveiras10",
          "kind" => "percent",
          "value" => 10
        })

      assert {:ok, order} =
               VipShop.create_order(customer, package, link, "stripe", coupon: "CAVEIRAS10")

      assert order.amount_cents == 1791
      assert order.discount_cents == 199

      {:ok, _paid} = VipShop.mark_paid(order)
      assert VipShop.get_coupon!(coupon.id).uses == 1

      assert {:error, :invalid_coupon} =
               VipShop.create_order(customer, package, link, "stripe", coupon: "NOPE")
    end

    test "a gift goes to any player", %{a: a} do
      package = package_fixture([a])
      {customer, _link} = customer_with_player()
      gift = %{player_id: "7656999", player_name: "Friend", gift: true}

      assert {:ok, order} = VipShop.create_order(customer, package, gift, "stripe")
      assert order.gift
      assert order.player_id == "7656999"
    end

    test "an admin gives VIP for free", %{a: a} do
      package = package_fixture([a])

      assert {:ok, order} = VipShop.grant_manually(package, "7656", "Prize", "Admin")
      assert order.status == "paid"
      assert order.amount_cents == 0
      assert order.granted_by == "Admin"
      assert_enqueued(worker: FulfillVipOrder, args: %{order_id: order.id})
    end
  end

  describe "reminders and alerts" do
    test "customers are reminded once before the VIP ends", %{a: a} do
      package = package_fixture([a])
      {customer, link} = customer_with_player()
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      HllConditionalActions.Repo.insert!(%Grant{
        order_id: order.id,
        server_id: a.id,
        server_name: "A",
        status: "granted",
        expires_at: DateTime.add(DateTime.utc_now(:second), 2 * 86_400, :second)
      })

      assert VipShop.send_expiry_reminders("https://shop") == 1
      assert_enqueued(worker: SendShopEmail, args: %{"template" => "expiring"})
      assert VipShop.send_expiry_reminders("https://shop") == 0
    end

    test "a failed paid order shows in the Attention inbox", %{a: a} do
      package = package_fixture([a])
      {customer, link} = customer_with_player()

      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        case conn.request_path do
          "/api/get_vip_ids" ->
            Req.Test.json(conn, %{"result" => [], "failed" => false})

          "/api/add_vip" ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "down", "failed" => true})
        end
      end)

      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")
      {:ok, _paid} = VipShop.mark_paid(order)
      {:ok, %{status: "failed"}} = order.id |> VipShop.get_order() |> VipShop.fulfill()

      admin = user_fixture()
      %{open: open} = Attention.items(admin, [a], %{})
      assert Enum.any?(open, &(&1.kind == :vip_failed))
    end
  end

  describe "design" do
    test "saves theme, sections and headings" do
      current = Design.get(%{})

      design =
        Design.from_params(
          %{
            "theme" => "crimson",
            "hero" => "split",
            "sections" => %{"packages" => "true", "faq" => "false"},
            "titles" => %{"packages_subtitle" => "Escolha seu plano", "faq" => ""},
            "benefits" => %{
              "0" => %{"icon" => "bolt", "title" => "Fila", "text" => ""},
              "1" => %{"title" => ""}
            }
          },
          current
        )

      {:ok, _settings} = VipShop.update_design(design)
      saved = Design.get(VipShop.settings().design)

      assert saved["theme"] == "crimson"
      assert Design.enabled_sections(saved) == ["packages"]
      assert saved["titles"] == %{"packages_subtitle" => "Escolha seu plano"}
      assert [%{"title" => "Fila"}] = saved["benefits"]
      assert saved["accent"] == nil
    end
  end

  describe "admin fidelity" do
    defp paid_order(package, attrs \\ %{}) do
      {:ok, customer} =
        VipShop.register_customer(%{
          "name" => "Lima",
          "email" => "lima#{System.unique_integer([:positive])}@example.com",
          "password" => "secret1234"
        })

      {:ok, link} = VipShop.link_player(customer, "76561190000000003", "Santos")
      {:ok, order} = VipShop.create_order(customer, package, link, "stripe")

      order
      |> Ecto.Changeset.change(
        Map.merge(%{status: "fulfilled", paid_at: DateTime.utc_now(:second)}, attrs)
      )
      |> HllConditionalActions.Repo.update!()
    end

    test "packages are archived, duplicated and reordered", %{a: a} do
      first = package_fixture([a], %{"name" => "Mensal"})
      second = package_fixture([a], %{"name" => "Trimestral"})

      {:ok, copy} = VipShop.duplicate_package(first, "Ana")
      assert copy.name == "Mensal (2)"
      refute copy.active
      assert copy.updated_by == "Ana"

      :ok = VipShop.reorder_packages([second.id, copy.id, first.id])
      assert Enum.map(VipShop.list_packages(), & &1.id) == [second.id, copy.id, first.id]

      {:ok, _archived} = VipShop.archive_package(copy, "Ana")
      refute copy.id in Enum.map(VipShop.list_packages(), & &1.id)
    end

    test "a coupon honours its packages, its start and once per customer", %{a: a} do
      monthly = package_fixture([a])
      founder = package_fixture([a], %{"name" => "Fundador", "price" => "149.90"})

      {:ok, _coupon} =
        VipShop.save_coupon(
          %Coupon{},
          %{
            "code" => "ONLY",
            "kind" => "percent",
            "value" => 10,
            "package_ids" => [monthly.id],
            "once_per_customer" => true
          },
          "Ana"
        )

      assert {:ok, %Coupon{created_by: "Ana"}, 199} = VipShop.apply_coupon("only", monthly)
      assert {:error, :invalid_coupon} = VipShop.apply_coupon("only", founder)

      {customer, link} = customer_with_player()
      {:ok, order} = VipShop.create_order(customer, monthly, link, "stripe", coupon: "ONLY")
      {:ok, _paid} = VipShop.mark_paid(order)

      assert {:error, :invalid_coupon} =
               VipShop.create_order(customer, monthly, link, "stripe", coupon: "ONLY")

      {:ok, later} =
        VipShop.save_coupon(%Coupon{}, %{
          "code" => "LATER",
          "kind" => "percent",
          "value" => 5,
          "starts_at" => DateTime.add(DateTime.utc_now(:second), 86_400)
        })

      assert Coupon.state(later) == :scheduled
      assert {:error, :invalid_coupon} = VipShop.apply_coupon("LATER", monthly)
    end

    test "a manual grant picks its own days and servers", %{a: a, b: b} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        case conn.request_path do
          "/api/get_vip_ids" -> Req.Test.json(conn, %{"result" => [], "failed" => false})
          "/api/add_vip" -> Req.Test.json(conn, %{"result" => true, "failed" => false})
        end
      end)

      assert {:error, :no_server} =
               VipShop.grant_vip(%{player_id: "765", duration_days: 10, server_ids: []})

      {:ok, order} =
        VipShop.grant_vip(%{
          player_id: "76561190000000002",
          player_name: "Nogueira",
          duration_days: 10,
          server_ids: [to_string(b.id)],
          reason: "Event prize",
          admin: "Ana"
        })

      assert order.status == "paid"
      assert order.server_ids == [b.id]
      {:ok, order} = VipShop.fulfill(VipShop.get_order(order.id))

      assert order.status == "fulfilled"
      assert [%Grant{server_name: "B", status: "granted"}] = order.grants
      refute a.id in order.server_ids
    end

    test "a refund removes the VIP it granted", %{a: a} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        Req.Test.json(conn, %{"result" => true, "failed" => false})
      end)

      order = paid_order(package_fixture([a]))

      HllConditionalActions.Repo.insert!(%Grant{
        order_id: order.id,
        server_id: a.id,
        server_name: "A",
        status: "granted"
      })

      {:ok, refunded} = VipShop.refund_order(order, "Ana")
      assert refunded.status == "refunded"
      assert refunded.refunded_by == "Ana"
      assert [%Grant{status: "removed"}] = refunded.grants
      assert {:error, :not_paid} = VipShop.refund_order(refunded, "Ana")
    end

    test "the storefront is edited as a draft and published" do
      settings = VipShop.settings()
      assert VipShop.unpublished_changes(settings) == 0

      draft =
        settings
        |> VipShop.design_draft()
        |> Map.put("theme", "arctic")
        |> put_in(["titles", "hero"], "Jogue com vaga garantida")

      {:ok, settings} = VipShop.save_design_draft(draft)
      assert VipShop.unpublished_changes(settings) == 2
      assert Design.get(settings.design)["theme"] == "tactical"

      {:ok, settings} = VipShop.publish_design()
      assert settings.design_draft == nil
      assert Design.get(settings.design)["theme"] == "arctic"
      assert Design.get(settings.design)["titles"]["hero"] == "Jogue com vaga garantida"
    end

    test "a closed shop is not open" do
      assert VipShop.open?()
      {:ok, _settings} = VipShop.set_closed(true)
      refute VipShop.open?()
    end

    test "the overview counts revenue, gifts, active VIPs and pending deliveries", %{a: a} do
      package = package_fixture([a])
      order = paid_order(package, %{gift: true})

      HllConditionalActions.Repo.insert!(%Grant{
        order_id: order.id,
        server_id: a.id,
        server_name: "A",
        status: "granted",
        expires_at: DateTime.add(DateTime.utc_now(:second), 3 * 86_400)
      })

      failing = paid_order(package, %{status: "partial"})

      HllConditionalActions.Repo.insert!(%Grant{
        order_id: failing.id,
        server_id: a.id,
        server_name: "A #1",
        status: "failed"
      })

      stats = Stats.overview()
      assert stats.revenue == 2 * 1990
      assert stats.paid_orders == 2
      assert stats.gifts == 1
      assert stats.active_vips == 1
      assert stats.expiring_week == 1
      assert stats.pending_delivery == 1
      assert stats.failing_servers == ["A #1"]
      assert Stats.package_sales() == %{package.id => 2}
      assert Stats.bucket_counts([])[:paid] == 2
    end

    test "e-mails go out as HTML and plain text, with the order summary" do
      settings = %Settings{mail_from_address: "shop@example.com", shop_title: "Brigada"}

      email =
        Emails.build_text(
          settings,
          "Pago: {package}",
          "Oi **{name}**!\n[resumo do pedido]\n[botão: Acompanhar → {shop_url}]",
          "ana@example.com",
          %{
            "name" => "Ana",
            "package" => "VIP",
            "shop_url" => "https://x/o/1",
            "amount" => "R$ 1,00"
          }
        )

      assert email.subject == "Pago: VIP"
      assert email.html_body =~ "<strong>Ana</strong>"
      assert email.html_body =~ ~s(href="https://x/o/1")
      assert email.text_body =~ "Acompanhar: https://x/o/1"
      assert email.text_body =~ "R$ 1,00"
    end

    test "receipts and reminders follow the customer's email preferences", %{a: a} do
      Req.Test.stub(HllConditionalActions.Crcon, fn conn ->
        case conn.request_path do
          "/api/get_vip_ids" -> Req.Test.json(conn, %{"result" => [], "failed" => false})
          "/api/add_vip" -> Req.Test.json(conn, %{"result" => true, "failed" => false})
        end
      end)

      {customer, link} = customer_with_player()

      {:ok, _preference} =
        Storefront.update_preferences(customer, %{
          "receipts" => false,
          "expiry_reminders" => false
        })

      {:ok, order} = VipShop.create_order(customer, package_fixture([a]), link, "stripe")
      {:ok, _paid} = VipShop.mark_paid(order)
      {:ok, order} = order.id |> VipShop.get_order() |> VipShop.fulfill()

      assert order.status == "fulfilled"
      refute_enqueued(worker: SendShopEmail, args: %{"template" => "purchase"})

      order.grants
      |> Enum.map(& &1.id)
      |> then(fn ids ->
        HllConditionalActions.Repo.update_all(
          Ecto.Query.from(g in Grant, where: g.id in ^ids),
          set: [expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)]
        )
      end)

      assert VipShop.send_expiry_reminders("https://shop") == 1
      refute_enqueued(worker: SendShopEmail, args: %{"template" => "expiring"})
    end

    test "passwords need 10 characters and reset links last 30 minutes" do
      assert {:error, changeset} =
               VipShop.register_customer(%{
                 "name" => "Bo",
                 "email" => "bo@example.com",
                 "password" => "123456789"
               })

      assert %{password: [_too_short]} = errors_on(changeset)
      assert HllConditionalActions.VipShop.CustomerToken.reset_validity_minutes() == 30
      assert Storefront.reset_validity_minutes() == 30

      {customer, _link} = customer_with_player()
      parent = self()

      :ok =
        VipShop.request_password_reset(customer.email, fn token ->
          send(parent, {:token, token})
          "https://x/#{token}"
        end)

      assert_received {:token, token}

      HllConditionalActions.Repo.update_all(
        HllConditionalActions.VipShop.CustomerToken,
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -31 * 60)]
      )

      refute VipShop.customer_by_reset_token(token)
    end

    test "webhooks are logged" do
      :ok = VipShop.record_webhook("stripe", {:ok, "checkout.session.completed"}, %{order_id: 7})
      :ok = VipShop.record_webhook("stripe", {:error, "bad signature"}, %{event: "x"})

      assert [%{ok: false, error: "bad signature"}, %{ok: true, order_id: 7}] =
               Stats.webhooks()

      assert Stats.webhook_counts() == %{ok: 1, refused: 1}
    end
  end
end
