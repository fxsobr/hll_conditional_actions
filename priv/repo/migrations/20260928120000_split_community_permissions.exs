defmodule HllConditionalActions.Repo.Migrations.SplitCommunityPermissions do
  use Ecto.Migration

  # Statistics, progression and Discord used to borrow the monitoring and rule
  # permissions. Every role keeps exactly what it could reach before, then the
  # built-in roles are brought in line with their new definitions (roles are
  # only seeded when missing, so the boot task cannot do it).
  def up do
    execute("""
    UPDATE roles SET permissions = permissions || ARRAY['view_stats']::varchar[]
     WHERE (permissions && ARRAY['view_executions', 'view_live_feed']::varchar[])
       AND NOT ('view_stats' = ANY(permissions))
    """)

    execute("""
    UPDATE roles SET permissions = permissions || ARRAY['view_progression']::varchar[]
     WHERE (permissions && ARRAY['view_rules']::varchar[])
       AND NOT (permissions && ARRAY['view_progression', 'manage_progression']::varchar[])
    """)

    execute("""
    UPDATE roles SET permissions = permissions || ARRAY['manage_progression', 'manage_integrations']::varchar[]
     WHERE 'manage_rules' = ANY(permissions)
       AND NOT ('manage_progression' = ANY(permissions))
    """)

    execute("""
    UPDATE roles SET permissions = permissions || ARRAY['view_stats', 'view_progression', 'manage_progression', 'manage_integrations', 'view_tickets', 'manage_tickets']::varchar[]
     WHERE name = 'Administrator' AND system = true
    """)

    execute("""
    UPDATE roles
       SET permissions = array_remove(permissions, 'manage_integrations') || ARRAY['manage_tickets']::varchar[],
           description = 'Runs the servers day to day: rules, seasons, achievements and player tickets. Cannot change server credentials, integrations or access.'
     WHERE name = 'Operator' AND system = true
    """)

    execute("""
    UPDATE roles
       SET permissions = permissions || ARRAY['view_tickets']::varchar[],
           description = 'Read only access to servers, rules, history, statistics, seasons and tickets.'
     WHERE name = 'Viewer' AND system = true
    """)

    execute("""
    UPDATE roles SET permissions = ARRAY(SELECT DISTINCT unnest(permissions))
    """)
  end

  def down do
    execute("""
    UPDATE roles
       SET permissions = array_remove(array_remove(array_remove(array_remove(permissions,
             'view_stats'), 'view_progression'), 'manage_progression'), 'manage_integrations')
    """)
  end
end
