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
          optional(:questions) => [question()],
          id: atom(),
          icon: String.t(),
          tone: String.t(),
          attrs: map()
        }

  @typedoc """
  A question the recipe wizard asks before creating the rule; see
  `HllConditionalActions.Rules.RecipeAnswers`.
  """
  @type question :: %{
          required(:id) => atom(),
          required(:type) => :integer | :choice | :text,
          required(:target) => term(),
          optional(:min) => integer(),
          optional(:max) => integer(),
          optional(:options) => [atom()]
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
      top_command(),
      match_end_leaderboard(),
      top_support_vip(),
      mvp_vip(),
      best_squad_vip(),
      commander_reward(),
      squad_leader_reward(),
      achievements_command(),
      season_command(),
      melee_kill(),
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
      questions: [text(:message, {:action_param, 0, "message"})],
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
      questions: [
        %{id: :min_players, type: :integer, min: 0, max: 100, target: {:condition_value, 2}},
        %{
          id: :final_action,
          type: :choice,
          options: [:punish_player, :kick_player],
          target: :final_action
        }
      ],
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
      questions: [
        %{id: :min_players, type: :integer, min: 0, max: 100, target: {:condition_value, 1}},
        %{
          id: :final_action,
          type: :choice,
          options: [:punish_player, :kick_player],
          target: :final_action
        }
      ],
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
      questions: [
        %{id: :limit, type: :integer, min: 2, max: 8, target: {:ladder, 1}},
        %{
          id: :final_action,
          type: :choice,
          options: [:kick_player, :temp_ban_player, :perma_ban_player],
          target: :final_action
        },
        text(:message, {:action_param, 0, "message"})
      ],
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
      questions: [
        %{id: :max_players, type: :integer, min: 1, max: 100, target: {:condition_value, 0}},
        %{
          id: :vip_hours,
          type: :integer,
          min: 1,
          max: 720,
          target: {:action_param, 0, "duration_hours"}
        }
      ],
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
      questions: [text(:message, {:action_param, 0, "message"})],
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

  # The community top stats plugin's `!top`, as a rule: the player who asks
  # gets the live top three of the categories that matter, privately.
  defp top_command do
    %{
      id: :top_command,
      icon: "hero-trophy",
      tone: "primary",
      attrs: %{
        trigger_event: :chat_command,
        logical_operator: :and,
        cooldown_seconds: 60,
        conditions: [condition(:command, :equal, "top")],
        actions: [
          action(:message_player, %{
            "message" =>
              "TOP PLAYERS
Kills: {top_kills}
Teamplay: {top_teamplay}
" <>
                "Offense + defense: {top_offdef}

TOP SQUADS
" <>
                "Infantry: {top_infantry_squads}
Armor: {top_armor_squads}"
          })
        ]
      }
    }
  end

  # Everybody sees the table at the end of the match. Sent once: a message
  # to all players goes out for the first player of the sweep only.
  defp match_end_leaderboard do
    %{
      id: :match_end_leaderboard,
      icon: "hero-flag",
      tone: "primary",
      attrs: %{
        trigger_event: :match_end,
        logical_operator: :and,
        conditions: [condition(:always_true, :equal, "")],
        actions: [
          action(:message_all_players, %{
            "message" =>
              "MATCH TOP
Kills: {top_kills}
Support: {top_support}
" <>
                "Defense: {top_defense}
Best squads: {top_infantry_squads}"
          })
        ]
      }
    }
  end

  # ── Rewarding performance ───────────────────────────────────────────────

  # The match's MVP by teamplay (combat + support): the one who both fought
  # and kept the team going.
  defp mvp_vip do
    reward_recipe(:mvp_vip, "hero-star", [condition(:rank_teamplay, :equal, "1")],
      vip: 24,
      description: "MVP of the match",
      message: "You were the MVP of this match! You have VIP for 24 hours."
    )
  end

  # Every member of the best infantry squad: the sweep evaluates each player,
  # so the whole squad matches, each one once.
  defp best_squad_vip do
    reward_recipe(
      :best_squad_vip,
      "hero-user-group",
      [condition(:squad_rank, :equal, "1"), condition(:squad_type, :equal, "infantry")],
      vip: 12,
      description: "Best squad of the match",
      message: "Your squad was the best of the match! You have VIP for 12 hours."
    )
  end

  # ── Rewarding who helps the server ──────────────────────────────────────

  # Nobody wants to command; the ones who do, for a whole match, keep the
  # server playable.
  defp commander_reward do
    reward_recipe(
      :commander_reward,
      "hero-megaphone",
      [condition(:is_commander, :equal, "true")],
      playtime: 2400,
      vip: 24,
      description: "Thanks for commanding",
      message: "Thanks for commanding this match! You have VIP for 24 hours."
    )
  end

  defp squad_leader_reward do
    reward_recipe(
      :squad_leader_reward,
      "hero-flag",
      [
        condition(:is_squad_leader, :equal, "true"),
        condition(:squad_size, :greater_than_or_equal, "4")
      ],
      playtime: 2400,
      vip: 12,
      description: "Thanks for leading a squad",
      message: "Thanks for leading your squad this match! You have VIP for 12 hours."
    )
  end

  # The shape every match end reward shares: it needs a real match (a full
  # enough server, half an hour played) and pays out once a day at most.
  defp reward_recipe(id, icon, conditions, opts) do
    %{
      id: id,
      icon: icon,
      tone: "success",
      attrs: %{
        trigger_event: :match_end,
        logical_operator: :and,
        max_executions_per_player: 1,
        conditions:
          conditions ++
            [
              condition(
                :playtime_seconds,
                :greater_than_or_equal,
                to_string(Keyword.get(opts, :playtime, 1800))
              ),
              condition(:server_player_count, :greater_than_or_equal, "40")
            ],
        actions: [
          action(:grant_vip, %{
            "description" => Keyword.fetch!(opts, :description),
            "duration_hours" => Keyword.fetch!(opts, :vip)
          }),
          action(:message_player, %{"message" => Keyword.fetch!(opts, :message)})
        ]
      }
    }
  end

  # ── Achievements and seasons in chat ────────────────────────────────────

  defp achievements_command do
    %{
      id: :achievements_command,
      icon: "hero-trophy",
      tone: "info",
      attrs: %{
        trigger_event: :chat_command,
        logical_operator: :and,
        cooldown_seconds: 60,
        conditions: [condition(:command, :equal, "achievements")],
        actions: [
          action(:message_player, %{
            "message" => "Your achievements ({achievements_count}):
{achievements}"
          })
        ]
      }
    }
  end

  defp season_command do
    %{
      id: :season_command,
      icon: "hero-calendar-days",
      tone: "info",
      attrs: %{
        trigger_event: :chat_command,
        logical_operator: :and,
        cooldown_seconds: 60,
        conditions: [condition(:command, :equal, "season")],
        actions: [
          action(:message_player, %{
            "message" => "Your position this season: {season_rank}
Top: {season_top}"
          })
        ]
      }
    }
  end

  # A knife or spade kill is rare and the most personal thing in the game:
  # the killer hears whom they got. The weapon category, not the weapon's
  # name, so every faction's knife and spade count.
  defp melee_kill do
    %{
      id: :melee_kill,
      icon: "hero-scissors",
      tone: "info",
      attrs: %{
        trigger_event: :player_kill,
        logical_operator: :and,
        conditions: [condition(:weapon_type, :equal, "melee")],
        actions: [
          action(:message_player, %{
            "message" => "Melee kill! You got {target_player_name} with your {weapon}."
          })
        ]
      }
    }
  end

  # The reward half of top stats: the best supporter of the match, who
  # actually played it, gets VIP for a day.
  defp top_support_vip do
    %{
      id: :top_support_vip,
      icon: "hero-gift",
      tone: "success",
      attrs: %{
        trigger_event: :match_end,
        logical_operator: :and,
        max_executions_per_player: 1,
        conditions: [
          condition(:rank_support, :equal, "1"),
          condition(:playtime_seconds, :greater_than_or_equal, "1800"),
          condition(:server_player_count, :greater_than_or_equal, "40")
        ],
        actions: [
          action(:grant_vip, %{
            "description" => "Top support of the match",
            "duration_hours" => 24
          }),
          action(:message_player, %{
            "message" => "You were the best supporter of this match! You have VIP for 24 hours."
          })
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

  defp text(id, target), do: %{id: id, type: :text, target: target}

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
    |> Map.put_new_lazy(:exemptions, fn -> default_exemptions(attrs) end)
    |> reject_unknown()
  end

  @doc """
  The exemptions a recipe starts with: a recipe that punishes, kicks or bans
  leaves VIPs alone, so accepting it never turns on the players a community
  most wants to keep. Staff are exempted by flag in the builder, since CRCON
  names no admins in its player data.

      iex> alias HllConditionalActions.Rules.Recipes
      iex> Recipes.to_attrs(Recipes.fetch(:team_kill_ladder), name: "x").exemptions
      %{exempt_vip: true}
      iex> Recipes.to_attrs(Recipes.fetch(:welcome), name: "x").exemptions
      %{}
  """
  @spec default_exemptions(map()) :: map()
  def default_exemptions(attrs) do
    punishing = Catalog.actions_in_group(:punishment)

    if Enum.any?(Map.get(attrs, :actions, []), &(&1.type in punishing)),
      do: %{exempt_vip: true},
      else: %{}
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
