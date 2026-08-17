🧭 You are here : [Wiki home](https://github.com/fxsobr/hll_conditional_actions/wiki/Home) / User Guide / Rules / [Operators](https://github.com/fxsobr/hll_conditional_actions/wiki/User-Guide-%E2%80%90-Rules-%E2%80%90-Operators)
***

# Rules ‐ Operators

## Menu

- [Two rules that apply to all of them](#two-rules-that-apply-to-all-of-them)
- [is](#is)
- [is not](#is-not)
- [contains](#contains)
- [does not contain](#does-not-contain)
- [starts with](#starts-with)
- [ends with](#ends-with)
- [matches the pattern](#matches-the-pattern)
- [is one of](#is-one-of)
- [is none of](#is-none-of)
- [is greater than](#is-greater-than)
- [is at least](#is-at-least)
- [is less than](#is-less-than)
- [is at most](#is-at-most)
- [Which operators each field offers](#which-operators-each-field-offers)

***

## Two rules that apply to all of them

**Text comparison ignores case and surrounding spaces.** `contains` `ADMIN`
matches `admin`, `Admin` and ` admin `. The one exception is **matches the
pattern**, which is a regular expression and is case sensitive unless you tell
it otherwise.

**A value that cannot be read never matches.** If the field is unavailable —
`Weapon` on a connect rule, level before the connect delay has passed — the
condition is false. It is never treated as "true by default", and it does not
error.

---

## is

Exactly equal. On numbers it compares numerically, so `10` and `10.0` are the
same; on yes/no fields it compares the boolean.

| Field | Value | Matches | Does not match |
| --- | --- | --- | --- |
| `Role` **is** | `tankcommander` | a tank commander | a rifleman |
| `Player name` **is** | `Kapitan` | `Kapitan`, `kapitan`, `KAPITAN ` | `Kapitan2`, `[CB] Kapitan` |
| `Is VIP` **is** | `yes` | a VIP | everybody else |
| `Level` **is** | `1` | level 1 | level 2 |
| `Times this rule already hit this player` **is** | `0` | the first time only | any repeat |

**Use it for:** the first offence only, a specific role, an exact map.

---

## is not

The opposite of *is*.

| Field | Value | Matches |
| --- | --- | --- |
| `Team` **is not** | `allies` | everybody on Axis |
| `Game mode` **is not** | `warfare` | Offensive, Skirmish… |
| `Is the squad leader` **is not** | `yes` | every player who is not the officer |

**Use it for:** exempting one case without listing all the others.

---

## contains

The text appears **somewhere** inside the value.

| Field | Value | Matches | Does not match |
| --- | --- | --- | --- |
| `Player name` **contains** | `[CB]` | `[CB] Kapitan`, `xx[cb]xx` | `CB Kapitan` |
| `Chat message` **contains** | `admin` | `need an admin here`, `ADMIN!!` | `adm` |
| `Weapon` **contains** | `SATCHEL` | every satchel charge variant | a rifle |
| `Flags` **contains** | `🚩` | a player carrying that flag in CRCON | anybody without it |

On **Flags** — a list, not text — *contains* asks about **membership**: is this
exact flag on the player. It is not a substring search.

**Use it for:** clan tags typed into the name, word filters, weapon families.

---

## does not contain

The text appears nowhere in the value. The operator in the screenshot at the
top of most word-filter rules.

| Field | Value | Matches |
| --- | --- | --- |
| `Player name` **does not contain** | `[CB]` | everybody who is not wearing your tag |
| `Flags` **does not contain** | `✅` | everybody an admin has not vouched for |
| `Chat message` **does not contain** | `gg` | any message that is not just a `gg` |

**Use it for:** "everybody except our members", "unless an admin has flagged
them".

> [!TIP]
> `Player name` **does not contain** `[CB]` and `Flags` **does not contain**
> `✅`, combined with **All conditions must hold**, is the standard "applies to
> everybody except our people" pair.

---

## starts with

The value begins with the text.

| Field | Value | Matches | Does not match |
| --- | --- | --- | --- |
| `Player name` **starts with** | `[CB]` | `[CB] Kapitan` | `xx [CB] Kapitan` |
| `Chat message` **starts with** | `!` | any command | a normal sentence |
| `Map` **starts with** | `carentan` | every Carentan variant — day, dusk, night | Foy |

**Use it for:** tags that must be at the front, map families (a map name
carries its time of day at the end).

---

## ends with

The value finishes with the text.

| Field | Value | Matches |
| --- | --- | --- |
| `Map` **ends with** | `_night` | every night map |
| `Map` **ends with** | `_offensive` | every offensive layout |
| `Player name` **ends with** | `_bot` | names that end that way |

**Use it for:** map variants, naming conventions with a suffix.

---

## matches the pattern

A regular expression. The most powerful operator and the one worth being
careful with.

Unlike every other text operator, **this one is case sensitive**. Start the
pattern with `(?i)` to make it insensitive.

| Field | Pattern | Matches |
| --- | --- | --- |
| `Player name` **matches the pattern** | `^\[.*\]` | any name starting with a bracketed tag |
| `Player name` **matches the pattern** | `(?i)n[i1l]gg` | slur variants written with digits |
| `Player name` **matches the pattern** | `^[^a-zA-Z0-9]+$` | names made only of symbols |
| `Chat message` **matches the pattern** | `(?i)\b(hack|cheat|aimbot)\b` | any of those words, as whole words |
| `Player ID` **matches the pattern** | `^7656119\d{10}$` | a well formed Steam64 id |

An invalid pattern never matches — it does not crash the rule, it just returns
false. If a pattern rule never fires, test the expression somewhere like
[regex101](https://regex101.com/) first.

**Use it for:** name filters that have to survive people writing `a` as `4`,
and anything with alternatives.

---

## is one of

A comma separated list. The value has to equal **one** of the entries. Spaces
around the commas are trimmed.

| Field | Value | Matches |
| --- | --- | --- |
| `Role` **is one of** | `tankcommander, crewman` | anybody in a tank crew |
| `Map` **is one of** | `carentan_warfare, foy_warfare, hill400_warfare` | only those three maps |
| `Day of the week` **is one of** | `saturday, sunday` | the weekend |
| `Level` **is one of** | `1, 2, 3` | levels 1 to 3 |
| `Player ID` **is one of** | `76561198000000001, 76561198000000002` | those two accounts |

**Use it for:** several exact values without writing several conditions and
switching the combinator to *any*.

---

## is none of

The value equals none of the entries.

| Field | Value | Matches |
| --- | --- | --- |
| `Player ID` **is none of** | `76561198000000001, 76561198000000002` | everybody except your two admins |
| `Map` **is none of** | `kursk_warfare, stalingrad_warfare` | every map except those |
| `Role` **is none of** | `armycommander, officer, tankcommander, spotter` | every player who is not leading anything |

**Use it for:** an allowlist of exceptions.

---

## is greater than

Numbers only. **Strictly** greater.

| Field | Value | Matches |
| --- | --- | --- |
| `Team kills` **is greater than** | `2` | 3 team kills and up |
| `Players on the server` **is greater than** | `80` | a busy server |
| `Kills per minute` **is greater than** | `2.5` | a suspicious rate |
| `Squad size` **is greater than** | `2` | squads of 3 or more |

---

## is at least

Greater **or equal**. Usually the one you actually mean.

| Field | Value | Matches |
| --- | --- | --- |
| `Hour of day (0-23)` **is at least** | `22` | 22:00 onwards, in the server's timezone |
| `Level` **is at least** | `50` | veterans |
| `Sessions played` **is at least** | `10` | a regular |
| `Time on this map (seconds)` **is at least** | `1800` | somebody who has been here half an hour |

---

## is less than

Strictly less.

| Field | Value | Matches |
| --- | --- | --- |
| `Level` **is less than** | `10` | brand new players |
| `Players on the server` **is less than** | `30` | a seeding server |
| `Match time remaining (seconds)` **is less than** | `300` | the last five minutes |
| `Sessions played` **is less than** | `2` | somebody's first visit |

---

## is at most

Less **or equal**.

| Field | Value | Matches |
| --- | --- | --- |
| `Squad size` **is at most** | `1` | somebody alone in a squad |
| `K/D ratio` **is at most** | `0.5` | a player having a hard time |
| `Team difference (players)` **is at most** | `2` | teams that are close enough to be fair |

---

## Which operators each field offers

The builder only shows the ones that make sense for the field:

| Field type | Operators |
| --- | --- |
| **Text** (name, role, map, chat…) | is · is not · contains · does not contain · starts with · ends with · matches the pattern · is one of · is none of |
| **Whole numbers** (level, kills, players…) | is · is not · is greater than · is at least · is less than · is at most · is one of · is none of |
| **Decimals** (K/D, kills per minute) | is · is not · is greater than · is at least · is less than · is at most |
| **Yes/no** (Is VIP, Is the commander…) | is · is not |
| **Lists** (Flags) | contains · does not contain |
