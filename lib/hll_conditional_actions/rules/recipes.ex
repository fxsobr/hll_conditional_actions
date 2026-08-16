defmodule HllConditionalActions.Rules.Recipes do
  @moduledoc """
  Ready-made rules an admin can start from instead of a blank form.

  Most of these are the CRCON automods (`no_leader`, `no_solotank`,
  `seeding_rules`, `level_thresholds`, `tk_autoban`) expressed in this app's
  vocabulary. That is deliberate: someone arriving from CRCON should find the
  rules they already run, and someone new should not have to invent
  moderation policy from an empty page.

  Every recipe is written to be **safe to accept**: each one starts in
  simulation, so it records what it *would* have done until the admin has
  read the history and turned it off. The ones that punish escalate rather
  than jumping straight to a kick.

  A recipe is only a starting point — it produces the same attribute map the
  builder posts, so the admin lands in the normal form with everything filled
  in and edits from there. Nothing here bypasses validation.

  The labels live in `HllConditionalActionsWeb.Labels` so they can be
  translated; this module holds only the shape.
  """

  alias HllConditionalActions.Rules.Catalog

  @type recipe :: %{
          id: atom(),
          icon: String.t(),
          tone: String.t(),
          attrs: map()
        }

  @doc """
  Every recipe, in the order the gallery shows them.
  """
  @spec all() :: [recipe()]
  def all do
    [
      welcome(),
      no_squad_leader(),
      solo_tank(),
      team_kill_ladder(),
      seeding_reward(),
      chat_command_discord(),
      new_player_watch()
    ]
  end

  @doc """
  One recipe by id, or `nil`.

      iex> HllConditionalActions.Rules.Recipes.fetch(:welcome).attrs.trigger_event
      :player_connected
      iex> HllConditionalActions.Rules.Recipes.fetch(:nope)
      nil
  """
  @spec fetch(atom() | String.t()) :: recipe() | nil
  def fetch(id) when is_binary(id) do
    Enum.find(all(), &(to_string(&1.id) == id))
  end

  def fetch(id) when is_atom(id), do: Enum.find(all(), &(&1.id == id))

  @doc """
  The ids of every recipe.
  """
  @spec ids() :: [atom()]
  def ids, do: Enum.map(all(), & &1.id)

  # ── The recipes ────────────────────────────────────────────────────────────

  defp welcome do
    %{
      id: :welcome,
      icon: "hero-hand-raised",
      tone: "info",
      attrs: %{
        trigger_event: :player_connected,
        logical_operator: :and,
        conditions: [condition(:always_true)],
        actions: [
          action(:message_player, %{
            "message" => "Welcome {player_name}! Have a good match."
          })
        ]
      }
    }
  end

  # CRCON's `no_leader` automod: a squad without an officer, warned twice and
  # then punished. The kick CRCON offers as a last step is left out on
  # purpose — it is the step most likely to be regretted, and adding it is one
  # click in the builder.
  defp no_squad_leader do
    %{
      id: :no_squad_leader,
      icon: "hero-user-group",
      tone: "warning",
      attrs: %{
        trigger_event: :periodic,
        trigger_interval_seconds: 60,
        logical_operator: :and,
        escalation_window_seconds: 900,
        conditions: [
          condition(:squad_has_leader, :equal, "false"),
          condition(:squad_size, :greater_than_or_equal, "3"),
          condition(:server_player_count, :greater_than_or_equal, "40")
        ],
        actions: [
          action(:message_player, %{
            "message" => "Your squad has no officer. Take the role or join another squad."
          }),
          action(:message_player, %{
            "message" => "Still no officer in your squad. Next time this costs you."
          }),
          action(:punish_player, %{"reason" => "Squad without an officer"})
        ]
      }
    }
  end

  # CRCON's `no_solotank`: one player holding an armour squad.
  defp solo_tank do
    %{
      id: :solo_tank,
      icon: "hero-truck",
      tone: "warning",
      attrs: %{
        trigger_event: :periodic,
        trigger_interval_seconds: 60,
        logical_operator: :and,
        escalation_window_seconds: 900,
        conditions: [
          condition(:squad_is_solo_armor, :equal, "true"),
          condition(:server_player_count, :greater_than_or_equal, "40")
        ],
        actions: [
          action(:message_player, %{
            "message" => "You are alone in an armor squad. Crew up or switch role."
          }),
          action(:punish_player, %{"reason" => "Solo tanking"})
        ]
      }
    }
  end

  # CRCON's `tk_autoban`, softened into a ladder: warn, punish, then a short
  # temporary ban rather than a permanent one.
  defp team_kill_ladder do
    %{
      id: :team_kill_ladder,
      icon: "hero-exclamation-triangle",
      tone: "error",
      attrs: %{
        trigger_event: :player_team_kill,
        logical_operator: :and,
        escalation_window_seconds: 3600,
        conditions: [condition(:always_true)],
        actions: [
          action(:message_player, %{
            "message" => "Watch your fire, {player_name}. That was a team mate."
          }),
          action(:punish_player, %{"reason" => "Team killing"}),
          action(:kick_player, %{"reason" => "Repeated team killing"}),
          action(:temp_ban_player, %{"reason" => "Repeated team killing", "duration_hours" => 2})
        ]
      }
    }
  end

  # CRCON's `seed_vip`: reward the people who fill an empty server.
  defp seeding_reward do
    %{
      id: :seeding_reward,
      icon: "hero-star",
      tone: "success",
      attrs: %{
        trigger_event: :periodic,
        trigger_interval_seconds: 300,
        logical_operator: :and,
        cooldown_seconds: 86_400,
        conditions: [
          condition(:server_player_count, :less_than_or_equal, "40"),
          condition(:playtime_seconds, :greater_than_or_equal, "1800")
        ],
        actions: [
          action(:grant_vip, %{"description" => "Seeding reward", "duration_hours" => 24}),
          action(:message_player, %{
            "message" => "Thanks for helping us seed! You have VIP for 24 hours."
          })
        ]
      }
    }
  end

  defp chat_command_discord do
    %{
      id: :chat_command_discord,
      icon: "hero-command-line",
      tone: "info",
      attrs: %{
        trigger_event: :chat_command,
        logical_operator: :and,
        cooldown_seconds: 60,
        conditions: [condition(:command, :equal, "discord")],
        actions: [
          action(:message_player, %{"message" => "Join us at discord.gg/your-invite"})
        ]
      }
    }
  end

  # CRCON's `level_thresholds`, as a watch rather than a punishment: a very
  # low level player joining is worth knowing about, not worth acting on.
  defp new_player_watch do
    %{
      id: :new_player_watch,
      icon: "hero-eye",
      tone: "info",
      attrs: %{
        trigger_event: :player_connected,
        logical_operator: :and,
        conditions: [condition(:player_level, :less_than, "10")],
        actions: [
          action(:message_player, %{
            "message" => "Welcome! Ask your squad for help, everyone starts somewhere."
          }),
          action(:add_to_watchlist, %{"reason" => "Very low level, joined recently"})
        ]
      }
    }
  end

  # ── Shaping ────────────────────────────────────────────────────────────────

  defp condition(field, operator \\ :equal, value \\ "") do
    %{field: field, operator: operator, value: value}
  end

  defp action(type, parameters), do: %{type: type, parameters: parameters}

  @doc """
  A recipe as the attributes the rule form expects.

  `name` is the translated title the caller passes in, and everything lands
  in simulation with the game and server the admin chose, so accepting a
  recipe can never punish anybody before it has been read.
  """
  @spec to_attrs(recipe(), keyword()) :: map()
  def to_attrs(%{attrs: attrs}, opts) do
    attrs
    |> Map.merge(%{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.get(opts, :description),
      game: Keyword.get(opts, :game, :hll),
      server_id: Keyword.get(opts, :server_id),
      group: Keyword.get(opts, :group),
      enabled: true,
      simulation: true
    })
    |> Map.update!(:conditions, &Enum.map(&1, fn c -> Map.new(c, fn {k, v} -> {k, v} end) end))
    |> reject_unknown()
  end

  # A recipe that names a field or action this build does not have would fail
  # deep inside the changeset; dropping it here keeps the rest usable.
  defp reject_unknown(attrs) do
    attrs
    |> Map.update(:conditions, [], fn conditions ->
      Enum.filter(conditions, &(&1.field in Catalog.fields()))
    end)
    |> Map.update(:actions, [], fn actions ->
      Enum.filter(actions, &(&1.type in Catalog.action_types()))
    end)
  end
end
