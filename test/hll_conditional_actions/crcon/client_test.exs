defmodule HllConditionalActions.Crcon.ClientTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Crcon
  alias HllConditionalActions.Crcon.Client
  alias HllConditionalActions.Crcon.Error

  doctest HllConditionalActions.Crcon.Client

  @conn %{base_url: "https://rcon.example.com", api_key: "secret-key"}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "request/4" do
    test "unwraps a successful envelope" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/get_gamestate"
        assert ["Bearer secret-key"] = Plug.Conn.get_req_header(conn, "authorization")

        envelope(conn, %{"num_allied_players" => 25})
      end)

      assert {:ok, %{"num_allied_players" => 25}} = Crcon.get_gamestate(@conn)
    end

    test "turns a failed envelope into a command error" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "result" => nil,
          "failed" => true,
          "error" => "Player not found"
        })
      end)

      assert {:error, %Error{reason: :command_failed, message: "Player not found"}} =
               Crcon.punish(@conn, "76561190000000001", "Team killing")
    end

    test "reports a rejected API key as unauthorized" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

      assert {:error, %Error{reason: :unauthorized}} = Crcon.get_gamestate(@conn)
    end

    test "reports a missing endpoint separately, since CRCON versions differ" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)

      assert {:error, %Error{reason: :not_found}} = Crcon.get_gamestate(@conn)
    end

    test "a body without the envelope is an invalid response, not a command failure" do
      stub(fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, %Error{reason: :invalid_response}} = Crcon.get_gamestate(@conn)
    end

    test "a transport failure is distinguishable from an HTTP error" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{reason: :transport_error}} =
               Crcon.get_gamestate(@conn) |> then(fn result -> result end)
    end
  end

  describe "verbs" do
    test "reads are GET and commands are POST, matching CRCON's own routing" do
      assert Client.method_for("get_detailed_players") == :get
      assert Client.method_for("describe_scoreboard_config") == :get
      assert Client.method_for("message_player") == :post
      assert Client.method_for("temp_ban") == :post
    end

    test "a command sends its arguments as a JSON body" do
      stub(fn conn ->
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "player_id" => "76561190000000001",
                 "duration_hours" => 2,
                 "reason" => "Team killing"
               }

        envelope(conn, true)
      end)

      assert {:ok, true} = Crcon.temp_ban(@conn, "76561190000000001", 2, "Team killing")
    end

    test "a read sends its arguments as query parameters" do
      stub(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params == %{
                 "player_id" => "76561190000000001",
                 "num_sessions" => "0"
               }

        envelope(conn, %{"sessions_count" => 12})
      end)

      assert {:ok, %{"sessions_count" => 12}} =
               Crcon.get_player_profile(@conn, "76561190000000001")
    end

    test "a trailing slash in the base URL does not produce a double slash" do
      stub(fn conn ->
        assert conn.request_path == "/api/get_gamestate"
        envelope(conn, %{})
      end)

      assert {:ok, _} = Crcon.get_gamestate(%{@conn | base_url: "https://rcon.example.com/"})
    end
  end

  describe "check_connection/1" do
    test "reports the key's permissions and the server it points at" do
      stub(fn conn ->
        case conn.request_path do
          "/api/get_own_user_permissions" ->
            envelope(conn, %{
              "is_superuser" => false,
              "user_name" => "conditional-actions",
              "permissions" => [%{"permission" => "can_view_structured_logs"}]
            })

          "/api/get_public_info" ->
            envelope(conn, %{
              "name" => %{"name" => "EU Warfare #1"},
              "player_count" => 87,
              "max_player_count" => 100,
              "current_map" => %{"map" => %{"pretty_name" => "Carentan"}}
            })
        end
      end)

      assert {:ok, info} = Crcon.check_connection(@conn)

      assert info.user_name == "conditional-actions"
      assert info.permissions.ok?
      assert info.server.name == "EU Warfare #1"
      assert info.server.player_count == 87
      assert info.server.current_map == "Carentan"
    end

    test "a bad key fails the check, since the probe requires authentication" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

      assert {:error, %Error{reason: :unauthorized}} = Crcon.check_connection(@conn)
    end

    test "the server description is optional" do
      stub(fn conn ->
        case conn.request_path do
          "/api/get_own_user_permissions" ->
            envelope(conn, %{"is_superuser" => false, "permissions" => []})

          _other ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      assert {:ok, info} = Crcon.check_connection(@conn)
      assert info.server == nil
      # No structured-logs permission, so the key is still not acceptable.
      refute info.permissions.ok?
    end
  end

  defp stub(fun), do: Req.Test.stub(HllConditionalActions.Crcon, fun)

  defp envelope(conn, result) do
    Req.Test.json(conn, %{
      "result" => result,
      "command" => "test",
      "failed" => false,
      "error" => nil,
      "version" => "v11.0.0"
    })
  end
end
