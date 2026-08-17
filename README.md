# HLL Conditional Actions

Rule automation for [Hell Let Loose](https://www.hellletloose.com/) servers, built on top of [CRCON](https://github.com/MarechJ/hll_rcon_tool).

![Elixir](https://img.shields.io/badge/Elixir-1.20-4B275F?logo=elixir&logoColor=white)
![Phoenix](https://img.shields.io/badge/Phoenix-1.8-FD4F00?logo=phoenixframework&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-compose-2496ED?logo=docker&logoColor=white)  
![CRCON Discord](https://img.shields.io/discord/685692524442026020?color=%237289da&label=CRCON%20discord)
![Last commit](https://img.shields.io/github/last-commit/fxsobr/hll_conditional_actions)

![Overview](docs/screenshots/overview.png)

*When **TRIGGER** happens, if **CONDITIONS** hold, run **ACTIONS**.* Welcome new players, warn team killers, escalate on repeat offenders, reward the people who seed, or post to Discord when something needs a human.

No scripting. A rule is built from dropdowns, reads back as a sentence, and can be tried against a player who is connected right now — or left in simulation, where it records everything it *would* have done without touching the game.

> [!IMPORTANT]
> **This app does not talk to Hell Let Loose. It talks to CRCON.**
> You need a working [CRCON](https://github.com/MarechJ/hll_rcon_tool) installation first: it is what holds the RCON connection, parses the game logs and exposes both as an API. Without one there is nothing for this app to read from or act on.

## Documentation

<table>
  <tbody>
    <tr>
      <th>Getting started</th>
      <th>User guide</th>
      <th>Running it</th>
      <th>For the devs</th>
      <th>Help</th>
    </tr>
    <tr>
      <td valign="top" nowrap>
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-What-it-does">What it does</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Requirements">Requirements</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation">Installation</a>
      </td>
      <td valign="top" nowrap>
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Connecting-a-CRCON-server">Connecting a server</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Writing-rules">Writing rules</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Triggers">When — triggers</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Conditions">If — conditions</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators">Operators</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Actions">Then — actions</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Users-roles-and-two-factor">Users and two factor</a>
      </td>
      <td valign="top" nowrap>
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Production-deployment">Production deployment</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Configuration">Configuration</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Security">Security</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Administration-%E2%80%90-Backups">Backups</a>
      </td>
      <td valign="top" nowrap>
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Architecture">Architecture</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Development-environment">Development environment</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Translations">Translations</a>
      </td>
      <td valign="top" nowrap>
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/wiki/Troubleshooting-%E2%80%90-Common-issues">Common issues</a><br />
        ● <a href="https://github.com/fxsobr/hll_conditional_actions/issues">Report an issue</a>
      </td>
    </tr>
  </tbody>
</table>

## Quick start

```bash
git clone git@github.com:fxsobr/hll_conditional_actions.git
cd hll_conditional_actions
cp .env.example .env          # fill in PHX_HOST, SECRET_KEY_BASE, ENCRYPTION_KEY, POSTGRES_PASSWORD
docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d
```

It answers on `http://<your machine>:4000`, leaving ports 80 and 443 alone. Sign in with `admin` / `admin` and you are asked to pick a new password immediately.

Full walkthrough: [Installation](https://github.com/fxsobr/hll_conditional_actions/wiki/Getting-Started-%E2%80%90-Installation).

## Screenshots

**The rule builder** — setup, trigger, conditions, actions and limits as steps, with the rule reading back in plain words beside them.

![The rule builder](docs/screenshots/rule-builder.png)

**A rule's own page** — how often it fired, how many players it reached, what failed, and every change ever made to it.

![A rule](docs/screenshots/rule.png)

## Thanks to CRCON

This project stands entirely on **[CRCON — Hell Let Loose Community RCON](https://github.com/MarechJ/hll_rcon_tool)**, by [MarechJ](https://github.com/MarechJ) and its contributors.

CRCON does the hard part — holding the RCON connection, parsing the game's logs into structured events, and putting a sane API in front of both. It is the reason this app can be a rule engine instead of a reimplementation of everything underneath. The recipes that ship here are modelled on CRCON's own automods, and its permission model is the one this app asks for and respects.

If you run a Hell Let Loose server, go and use CRCON. It is excellent.

- **GitHub:** <https://github.com/MarechJ/hll_rcon_tool>
- **Discord:** <https://discord.com/invite/zpSQQef>

## Contribute

Any contribution is welcome — code, documentation, or a translation.

The interface goes through gettext and ships in **English** and **Brazilian Portuguese**. Adding a language does not require knowing Elixir; see [Translations](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Translations).

Hell Let Loose is a trademark of Team17 / Expression Games. This is an unofficial community tool, not affiliated with either.
