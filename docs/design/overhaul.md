# Overhaul — "Posto de Comando"

The redesign lives on the design canvas **"HLL Conditional Actions — Overhaul"**
(claude.ai artifact, pages: Direção e início, Ao vivo, Regras, Construtor,
Caixa e tickets, Jogadores e comunidade, Loja VIP admin/pública, Ajustes). Its
**Tokens**, **Components** and **Handoff** boards are the source for this
migration. This file tracks what has moved into the app and what is next.

## Principles

1. One question per screen (Briefing: what needs me? Ao vivo: what is
   happening? Regra: is it working?).
2. Rules read as sentences; the node flow becomes a secondary view.
3. Simulation is a stage — Rascunho → Simulando → Ao vivo — with a readiness
   check before a rule touches the game.
4. The server is a filter, not a place: one switcher in the top bar scopes
   any page.

## How the migration works

The app's components already paint with semantic tokens (`bg-base-100`,
`text-primary`, `border-base-300`, Petal's `primary-*`/`gray-*` ramps). The
overhaul therefore starts by **changing what the tokens are**, which restyles
every page at once, and then reshapes navigation and screens one area at a
time. No page is rewritten until its area's phase.

## Phase 1 — foundation (done)

- `assets/css/app.css`: new token block — olive neutrals, lime signal
  (`primary`), lavender engine (`secondary`/`--color-engine`), team colours
  (`--color-allies`, `--color-axis`), larger radii; light (`:root`) and dark
  (`.dark`). Solid primary buttons use the signal with dark text in dark mode.
- Fonts self-hosted in `priv/static/fonts`: Schibsted Grotesk (UI),
  Bricolage Grotesque (`font-display`: titles, big numbers), JetBrains Mono
  (`font-mono`). Geist files are no longer referenced.
- `Layouts.app`: the 16rem sidebar became the **icon rail** (`rail/1`, from
  `xl`). Its areas (`Layouts.areas/2`): Briefing, Ao vivo (the scoped or first
  server's cockpit), Regras, Caixa (badge: attention items + open tickets),
  Comunidade, Jogadores, Módulos (marketplace), and Ajustes with the account
  avatar (menu: account, theme, language, about, sign out) at the bottom.
- Header (Shell fidelity pass): title (`crumb` above, `page_subtitle` under,
  `page_meta` inline, `badges` as pills, `back` as a round button), the
  area's pages as pill tabs beside the title (`tabs`: `:auto` / `false` / a
  list), then the global search (`global_search`, or the page's own `:search`
  slot), the scope pill with the server count (`scope`), the bell
  (`bell`) and the page's `:actions`. Beside inline tabs the search and the
  bell step aside on wide screens, as on the boards.
- Command palette (Ctrl K): `HllConditionalActionsWeb.CommandPalette`
  over `HllConditionalActions.Search` (players, rules that hit them, tickets,
  CRCON's recent matches, actions, pages). Bell: `NotificationsPanel` over
  `HllConditionalActions.Notifications` (unread per user in
  `notification_reads`).
- Tablets and phones: a floating tab bar (7 areas on a tablet, 4 + "Mais" on
  a phone) and the "Mais" sheet (`MoreSheet`); `tab_bar={false}` for pages
  with their own bottom bar.
- States board: `empty_state`, `loading_state` (kpis/table/feed),
  `error_state`, `no_permission`, `banner`, `confirm_dialog` in `Ui`; flash
  toasts restyled in `CoreComponents.flash/1`.

## Design tokens → Tailwind classes

Use these instead of hex values; they follow light and dark.

| Design | Class |
| --- | --- |
| ground (page) | `bg-base-200` |
| panel | `bg-base-100` + `rounded-[1.75rem]` (panels) / `rounded-box` (24px cards) |
| raised (rows, tiles inside a panel, inputs) | `bg-secondary` |
| hairline | `border-base-300` |
| text / text-2 / text-3 | `text-base-content` / `text-subtle` / `text-muted` |
| signal (live, primary action, positive delta) | `text-primary`, `bg-primary text-primary-content`, tint `bg-primary/12` |
| engine / simulation (lavender) | `text-accent`, tint `bg-accent/13` |
| Allies / Axis | `text-allies` / `text-axis`, `bg-allies`, tint `bg-allies/14` |
| attention / danger | `text-warning` `bg-warning/13` / `text-error` `bg-error/14` |
| display face (titles, big numbers) | `font-display` |
| ids, times, logs | `font-mono` |
| page title | the layout's `page_title` |
| panel title | `font-display text-xl font-semibold` |
| big number | `font-display text-[2.375rem] font-semibold leading-none` |

Components (`HllConditionalActionsWeb.Ui`): `card` (panel), `stat` and
`kpi_tile` (big numbers), `pill` (live · simulating · neutral · warning ·
error), `icon_tile`, `list_row`, `team_chip`/`team_text/1`, `sector_bar`,
`balance_bar`, `sparkline`, `medal`, `trace_chip`, `sub_tabs` (link tabs),
`segmented` (form choice), `empty_state`, `modal`, `data_table`,
`tone_badge` (adds the `engine` tone), `rule_state`.

Area styles that utilities cannot express go in `assets/css/areas/<area>.css`
(already imported by `app.css`).

## Phase 2 — shared components

Build the Handoff board's components in `components/ui.ex` and use them in
place of ad-hoc markup: `panel`, `kpi`, `pill` (ao vivo / simulando /
rascunho / pausada / erro), `team_chip`, `segmented`, `sub_tabs`, `list_row`,
`trace_chip`, `sector_bar`, `balance_bar`, `sparkline`, `medal`, `empty_state`,
`confirm_dialog`. Restyle `card`, `stat`, `data_table`, `tone_badge`,
`modal` and the flash toasts to the new shapes.

## Phase 3 — areas, in order

1. **Briefing** (`/`): greeting, KPI row, engine suggestion, fires chart,
   "Precisa de você", servers now.
2. **Ao vivo** (`/servers/:id`): photo hero with score, sectors and balance;
   feed with rule annotations inline; best of the match.
3. **Regras**: list grouped by folder; rule 360 with readiness banner, ladder
   and version diff; the **bancada de testes** builder (sentence, coloured
   groups, run strip overlay, 7-day replay).
4. **Caixa**: attention and tickets as one inbox with the conversation and
   the player context.
5. **Jogadores** (new): list and the 360 page.
6. **Comunidade**: seasons, achievements, matches, VIP shop admin.
7. **Ajustes** (new hub): servers, people, Discord, metrics, account.
8. Public shop themes and the auth screens.

New routes this needs: `/players`, `/settings` (hub), and the Caixa route
that joins `/attention` and `/tickets`.

## Phase 4 — polish

Light-theme pass on every page, phone and tablet layouts, empty/loading/
error states from the States board, motion, accessibility review.
