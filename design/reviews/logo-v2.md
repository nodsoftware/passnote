# Logo review, v2

Feedback on v1: too bland. Brief added: draw on the papal conclave, where the
cardinals are locked in until they agree, without making the mark complex.

## Directions

| Direction | Verdict |
| --- | --- |
| Chimney with smoke curl or puffs | Dropped: a lone chimney reads as a pipe or a letter "i". |
| Wax seal with C monogram | Dropped: ring around a C reads as ©; even scallops read as a gear. |
| Chapel with chimney and smoke | Dropped: generic "home" icon. |
| C with puffs escaping its opening | Dropped: reads as bubbles, and says data leaves the room. |
| Rose window of arches (peers, empty centre) | Dropped: loading spinner, then ship's wheel. |
| C billowing into smoke | Dropped: puffs read as beads; a cloud is the wrong signal for a server-less library. |
| Gothic door with keyhole | Chosen. |

## The mark

A locked Gothic chapel door with a keyhole: *cum clave*, the cardinals locked
in. A pointed arch makes it a chapel rather than a vault; the doorframe line
gives it detail without adding parts.

## Tests

| Test | Result |
| --- | --- |
| 16 / 32 px | Pass. Arch and keyhole read at 16 px; the frame line greys out there, which is acceptable. |
| One colour | Pass: `symbol-mono`. |
| Reversed | Pass: white on cardinal (app icon), parchment on ink. |
| Lookalike | Generic "locked door" icons are rectangular; the pointed arch sets it apart. Legal clearance still needed. |
| Contrast | Cardinal on white 7.8:1; white on cardinal 7.8:1; parchment on ink 15.0:1. Cardinal on ink is 2.3:1: never use it. |

## Construction

512 px artboard. Door: base y = 464, sides x = 112 and 400, springline y = 232,
pointed arch of radius 200 (apex y = 40). Frame line: 16 px wide, inset 28 px.
Keyhole: head radius 40 at (256, 300), stem 28 px to 52 px wide, base y = 400.

## Palette

| Name | Hex | Use |
| --- | --- | --- |
| Cardinal | `#A3162B` | Mark on light; background for the white app icon |
| Ink | `#1A1416` | Wordmark; dark backgrounds |
| Parchment | `#F2E8DC` | Mark and wordmark on ink |

## Applied to the docs, README and pub.dev

| Where | Asset | Check |
| --- | --- | --- |
| Docs header, light | `docs/assets/logo.svg`, cardinal door | Cardinal on paper `#FBF8F4`: 7.3:1 |
| Docs header, dark | `docs/assets/logo-dark.svg`, parchment door | Parchment on ink: 15.0:1 |
| Docs links, light | Cardinal `#A3162B` | 7.3:1 on paper |
| Docs links, dark | Rose `#F0909C` | 7.9:1 on ink; cardinal would be 2.4:1 |
| Favicon | `docs/assets/favicon.svg` | Switches to parchment on dark browser themes |
| README | `conclave-horizontal(-on-dark).svg` via `<picture>` | Parchment on GitHub dark `#0D1117`: 15.6:1 |
| pub.dev thumbnail | `packages/*/doc/conclave-logo.png` (app icon, 512 px) | White on cardinal: 7.8:1 |

Rendered both docs schemes in headless Chrome and looked: logo, headings
and the active nav item all use the brand colours.
