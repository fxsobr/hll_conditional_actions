🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / [Administration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration) / [Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups)
***

# Backups

Three things are worth keeping, and they are not the same kind of thing:

| What | Where | If you lose it |
| --- | --- | --- |
| The database | `db_data` volume | Rules, users and history are gone |
| `ENCRYPTION_KEY` | your `.env` | The database survives, but every CRCON key in it is unreadable and has to be entered again |
| `caddy_data` | volume | Nothing, while there is no certificate in it |

## The daily dump

Since 0.3.5 the stack dumps the database by itself: the `backup` service
writes `./backups/db-YYYY-MM-DD.dump` every day at `BACKUP_HOUR` (UTC, `06`
by default) and deletes dumps older than `BACKUP_KEEP_DAYS` (`14`). Check it
is running:

```bash
docker compose logs backup
ls -lh backups/
```

**Copy `./backups` off the machine** — rclone, rsync or your provider's
storage. A backup on the same disk does not survive losing the disk.

A dump by hand, before an upgrade for example:

```bash
docker compose exec backup sh -c 'pg_dump -Fc -f /backups/db-manual-$(date +%F-%H%M).dump'
```

## Restoring

The dumps are in Postgres's custom format, restored with `pg_restore`. Stop
the app first so nothing writes while the data comes back:

```bash
docker compose stop app
docker compose exec backup sh -c 'pg_restore --clean --if-exists -d "$PGDATABASE" /backups/db-2026-10-14.dump'
docker compose start app
```

Keep `.env` somewhere other than the same disk. A dump without its
`ENCRYPTION_KEY` restores everything except the ability to talk to any game
server.

***

**←** [Security](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Security) · **↑** [Administration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration) · [Commands](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Commands) **→**
