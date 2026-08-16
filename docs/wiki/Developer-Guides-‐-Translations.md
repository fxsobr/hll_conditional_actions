🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / Developer Guides / [Translations](https://github.com/fxsobr/hll_conditional_actions/wiki/Developer-Guides-%E2%80%90-Translations)
***

# Translations

The source language is English. After adding or changing a `gettext` call:

```bash
mix gettext.extract --merge
```

Then fill in the new entries in `priv/gettext/pt_BR/LC_MESSAGES/default.po`.

Visitors pick their language from **My account**; without a choice the app
follows the browser's `Accept-Language` header and falls back to
`DEFAULT_LOCALE`.

---
