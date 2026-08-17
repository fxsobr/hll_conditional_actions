🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Administration / [Configuration](https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Configuration)
***

# Configuration

See [`.env.example`](https://github.com/fxsobr/hll_conditional_actions/blob/main/.env.example) for the full list.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `DATABASE_URL` | prod | — | `ecto://user:pass@host/database` |
| `SECRET_KEY_BASE` | prod | — | Signs cookies and LiveView payloads. At least 64 characters (`openssl rand -base64 64 \| tr -d '
'`) |
| `ENCRYPTION_KEY` | prod | — | Encrypts CRCON API keys (`openssl rand -base64 32`) |
| `PHX_HOST` | prod | `example.com` | Public hostname |
| `PORT` | no | `4000` | HTTP port |
| `POOL_SIZE` | no | `10` | Database pool |
| `DEFAULT_LOCALE` | no | `en` | `en` or `pt_BR` |
| `ENGINE_ENABLED` | no | `true` | `false` serves the UI without connecting to CRCON |
| `EXECUTION_RETENTION_DAYS` | no | `30` | How long the rule history is kept |
| `CONNECT_DELAY_MS` | no | `5000` | How long to wait after a connect before evaluating rules |
| `DATABASE_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_NAME` | no | localhost/postgres | Development and test only |

**Losing `ENCRYPTION_KEY` means every stored CRCON API key has to be entered
again.** Keep it with your other secrets.

---
