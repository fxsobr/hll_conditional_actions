defmodule HllConditionalActions.Crcon.PermissionsTest do
  use ExUnit.Case, async: true

  alias HllConditionalActions.Crcon.Permissions
  alias HllConditionalActions.Rules.Catalog

  doctest HllConditionalActions.Crcon.Permissions

  defp payload(permissions, opts \\ []) do
    %{
      "is_superuser" => Keyword.get(opts, :superuser, false),
      "user_name" => Keyword.get(opts, :user_name, "conditional-actions"),
      "permissions" => Enum.map(permissions, &%{"permission" => &1, "description" => &1})
    }
  end

  describe "review/1" do
    test "a key with exactly the required permission passes" do
      review = Permissions.review(payload(["can_view_structured_logs"]))

      assert review.ok?
      assert review.excess == []
      assert review.missing_required == []
    end

    test "a key without the log stream permission cannot work" do
      review = Permissions.review(payload(["can_kick_players"]))

      refute review.ok?
      assert review.missing_required == ["can_view_structured_logs"]
    end

    test "a permission this app never calls is excess" do
      review =
        Permissions.review(
          payload([
            "can_view_structured_logs",
            "can_change_server_settings",
            "can_add_admin_roles"
          ])
        )

      refute review.ok?
      assert review.excess == ["can_add_admin_roles", "can_change_server_settings"]
    end

    test "a superuser key is refused however few permissions it lists" do
      review = Permissions.review(payload(["can_view_structured_logs"], superuser: true))

      refute review.ok?
      assert review.superuser?
    end

    test "the full set this app can use is accepted" do
      review = Permissions.review(payload(Permissions.allowed()))

      assert review.ok?
      assert review.unavailable_actions == []
    end

    test "reports which actions a key cannot perform" do
      review = Permissions.review(payload(["can_view_structured_logs", "can_message_players"]))

      assert review.ok?, "missing action permissions are a warning, not a rejection"
      assert :kick_player in review.unavailable_actions
      refute :message_player in review.unavailable_actions
    end

    test "accepts Django's dotted spelling" do
      review = Permissions.review(payload(["api.can_view_structured_logs"]))

      assert review.ok?
    end

    test "a payload without permissions is missing the required one" do
      review = Permissions.review(%{"is_superuser" => false})

      refute review.ok?
      assert review.missing_required == ["can_view_structured_logs"]
    end
  end

  describe "the permission map covers the action catalog" do
    # If an action is added without its CRCON permission, a key that passes the
    # review would still fail at run time with a permission error.
    test "every player-affecting action maps to a permission" do
      unmapped =
        Catalog.action_types()
        |> Enum.reject(&(&1 == :send_discord_webhook))
        |> Enum.reject(&Permissions.for_action/1)

      assert unmapped == [],
             "these actions have no CRCON permission mapped: #{inspect(unmapped)}"
    end

    test "every mapped permission is one the review allows" do
      for action <- Catalog.action_types(), permission = Permissions.for_action(action) do
        assert permission in Permissions.allowed()
      end
    end

    # The server form lists every permission by name. A permission added
    # without a label would silently fall back to its codename there, which is
    # the unreadable state the labels exist to avoid.
    test "every permission has a readable name" do
      unlabelled =
        Enum.filter(Permissions.allowed(), fn permission ->
          HllConditionalActionsWeb.Labels.crcon_permission(permission) == permission
        end)

      assert unlabelled == [],
             "these permissions have no friendly name: #{inspect(unlabelled)}"
    end
  end

  describe "coverage of the action catalogue" do
    test "every action that talks to CRCON declares the permission it needs" do
      # A missing mapping is silent: the rule health check simply never warns
      # that the key cannot do what the rule asks, and the failure only shows
      # up in the execution history after the fact.
      unmapped =
        HllConditionalActions.Rules.Catalog.action_types()
        |> Enum.reject(&HllConditionalActions.Crcon.Permissions.permission_for/1)

      # Discord is the one action that reaches somewhere other than CRCON.
      assert unmapped == [:send_discord_webhook]
    end
  end
end
