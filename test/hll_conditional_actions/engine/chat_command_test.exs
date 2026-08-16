defmodule HllConditionalActions.Engine.ChatCommandTest do
  @moduledoc """
  A chat line that opens with a command prefix has to reach both triggers: it
  is still chat, and it is also a command with a parsed name.
  """

  use HllConditionalActions.DataCase, async: true

  import HllConditionalActions.Fixtures

  alias HllConditionalActions.Crcon.Events
  alias HllConditionalActions.Crcon.Events.Event
  alias HllConditionalActions.Engine.Context
  alias HllConditionalActions.Engine.Evaluator

  defp chat_event(message) do
    %Event{
      type: :player_chat,
      action: "CHAT[Allies][Unit able]",
      player_id: "76561190000000001",
      player_name: "Chris",
      chat_message: message,
      occurred_at: DateTime.utc_now()
    }
  end

  defp context(server, message) do
    Context.build(server, :chat_command, player: player(), event: chat_event(message))
  end

  setup do
    %{server: server_fixture()}
  end

  describe "parsing" do
    test "splits the command from its arguments" do
      assert Context.parse_command("!vip please") == {"vip", "please"}
      assert Context.parse_command("!discord") == {"discord", ""}
      assert Context.parse_command("@admin help me") == {"admin", "help me"}
    end

    test "downcases the command so shouting still matches" do
      assert Context.parse_command("!VIP") == {"vip", ""}
    end

    test "ignores plain chat" do
      assert Context.parse_command("just talking") == {nil, nil}
      assert Context.parse_command("!") == {nil, nil}
      assert Context.parse_command(nil) == {nil, nil}
    end

    test "command?/1 agrees with the parser" do
      assert Context.command?("!vip")
      refute Context.command?("hello")
      refute Context.command?("!")
    end
  end

  describe "routing" do
    test "a command fires both the chat and the command trigger" do
      triggers = Events.triggers(chat_event("!vip please"))

      assert Enum.any?(triggers, &match?({:player_chat, _id, _name}, &1))
      assert Enum.any?(triggers, &match?({:chat_command, _id, _name}, &1))
    end

    test "plain chat fires only the chat trigger" do
      triggers = Events.triggers(chat_event("good game everyone"))

      assert [{:player_chat, _id, _name}] = triggers
    end
  end

  describe "condition fields" do
    test "expose the command and its arguments", %{server: server} do
      context = context(server, "!vip please")

      assert Evaluator.field_value(:command, context) == "vip"
      assert Evaluator.field_value(:command_args, context) == "please"
    end

    test "are nil for plain chat", %{server: server} do
      context = context(server, "hello")

      assert Evaluator.field_value(:command, context) == nil
      assert Evaluator.field_value(:command_args, context) == nil
    end

    test "the raw message is still readable", %{server: server} do
      context = context(server, "!vip please")

      assert Evaluator.field_value(:message_content, context) == "!vip please"
    end
  end
end
