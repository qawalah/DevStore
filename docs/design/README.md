# Design language (from CrossPaths)

One shared look for the apps built with Claude: deep navy surfaces, one living accent, drawn
line icons, a raised main action in the middle of the tab bar, and motion that explains.

- [`DESIGN.md`](DESIGN.md): the rules. Colours, type, shapes, components, motion, do's and
  don'ts. **This is what a Claude session reads.**
- [`reference/`](reference): code to copy from, taken from CrossPaths. Not a package: copy what
  you need and adapt it.

The source of truth is `DESIGN.md` in [`qawalah/crossedpaths`](https://github.com/qawalah/crossedpaths).
This folder is a copy for the other apps to fetch. When CrossPaths changes it, the copy here is
updated too (see "Keeping it current").

## Using it in another app

**1. Fetch it into the app repo** (from the app's folder):

```bash
curl -fsSL https://raw.githubusercontent.com/qawalah/devstore/main/docs/design/DESIGN.md -o DESIGN.md
```

Fetch again whenever you want the latest. Don't edit the app's copy; if the app needs a
difference, say so in the app's `CLAUDE.md` (step 2).

**2. Tell Claude to follow it.** Add this to the app's `CLAUDE.md`:

```markdown
## Design

UI follows `DESIGN.md` (the CrossPaths design language, shared through qawalah/devstore:
docs/design/DESIGN.md). Read it before any UI change. Reuse its tokens, icons, motion and
patterns; don't invent new ones. To refresh it, fetch
https://raw.githubusercontent.com/qawalah/devstore/main/docs/design/DESIGN.md.

Differences for this app: <none | list them>
```

**3. Or, in a chat, say:** "Fetch the design language from
`https://raw.githubusercontent.com/qawalah/devstore/main/docs/design/DESIGN.md`, save it as
`DESIGN.md`, and make the UI follow it."

## What stays the same, what can change

Keep the same in every app:
- the palette (night and day), the five accents, the status colours, and the rule that the accent is read from the theme, never hard-coded;
- IBM Plex Sans Arabic as the only typeface, and English plus Arabic with right-to-left support;
- the shapes (10 / 12 / 16 / 22 radii, pills), flat surfaces with a border, the line-icon style;
- the motion vocabulary (the easing, the durations, page slides, the pulse) and the reduced-motion rule.

Each app decides its own:
- the main action in the middle of the tab bar, its icon and when it pulses;
- its tabs (the bar is five, with the main action in the centre) and its first-start tutorial content;
- its signature piece. CrossPaths has the crossing and the date bar; another app should have its own, in the same language.

## The reference code

`reference/mobile/` (Expo and React Native):

| File | What it is | Needs |
|---|---|---|
| `motion.js` | The two easing curves, the reduced-motion setting, `tint()` | nothing |
| `icons.js`, `Icon.js` | The line-icon set and a component that draws one | `react-native-svg`, a `colors` object |
| `PulseRings.js` | The invitation pulse: rings that ripple out while the icon breathes | `motion.js` |
| `CrossingHero.js` | The animated app icon (routes draw in and cross, the pin drops). Replace the artwork with the app's own mark. | `react-native-svg`, `motion.js` |
| `TabBar.js` | The five-tab bar with the sliding pill and the raised middle button | `Icon`, `PulseRings`, `motion.js`, a `colors` object, `AppText.js`, and the app's own logo image |

`reference/web/tokens.css` has the CSS variables for both themes and the shared keyframes for
web apps.

The mobile files import a few things the app supplies (`colors` from a `theme.js`, `AppText`,
`i18n`). Replace those imports with the app's own equivalents.

## Keeping it current

When `DESIGN.md` changes in CrossPaths, copy it here and update the snapshot:

```bash
cp crossedpaths/DESIGN.md devstore/docs/design/DESIGN.md
```

Then refresh the files in `reference/` if the code they come from changed. The snapshot was
taken from CrossPaths at the commit named in the commit message of the change that added it.
