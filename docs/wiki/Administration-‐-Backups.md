🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Backups](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups)
***

# Backups

Three things are worth keeping, and they are not the same kind of thing:

| What | Where | If you lose it |
| --- | --- | --- |
| The database | `db_data` volume | Rules, users and history are gone |
| `ENCRYPTION_KEY` | your `.env` | The database survives, but every CRCON key in it is unreadable and has to be entered again |
| `caddy_data` | volume | A new certificate is requested on next boot, which Let's Encrypt rate limits |

A database dump on a schedule:

```bash
docker compose -f compose.prod.yaml exec -T db   pg_dump -U "$POSTGRES_USER" hll_conditional_actions | gzip > backup-$(date +%F).sql.gz
```

Keep `.env` somewhere other than the same disk. A dump without its
`ENCRYPTION_KEY` restores everything except the ability to talk to any game
server.
