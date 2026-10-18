# Logo v5: Passnote

## Brief

The name is Passnote: a note passed between desks in class. It travels from hand to hand, with no one in the middle, and only the people it's meant for read it. That's the library: devices pass encrypted changes directly to each other, with no server. v3 (Cloister) was too religious; v4 (Kinfold) was rejected as a name and as a mark.

## Mark

A capital P cut from a single sheet. The bottom-right corner of the bowl is turned back, as when someone opens a folded note. The P gives the initial, and the turned corner says "a note".

- Grid: 512 px with an 8 px unit. The stem is 88 wide, the bowl 280 × 240, the counter 88 × 72 and the folded corner 88.
- The folded corner sits apart from the counter, so they don't merge at small sizes.

Dropped sketches: a Z-folded sheet (looks like a map icon), a note with a tucked tab (reads as a tag or pencil), a square with a flap (reads as a K or Pac-Man), a paper "football" (reads as a pyramid) and a half-open sheet (reads as a door).

## Colour

| Token | Hex | Use | Contrast |
| --- | --- | --- | --- |
| Ballpoint | `#2443B8` | Mark, links | 8.17:1 on white |
| Fold | `#8FA3E6` | Folded corner | 3.33:1 on Ballpoint; 6.93:1 on Night |
| Night | `#141B33` | Wordmark, dark backgrounds | — |
| Paper | `#F4F1E8` | Reversed mark | 15.06:1 on Night |

Ballpoint blue is the ink of a school pen. The fold colour is decorative and isn't needed to read the mark; the one-colour version shows the fold as a 12 px cut instead.

## Tests

| Test | Result |
| --- | --- |
| 16 px | Reads as a P; the folded corner shows as a lighter step. Counter is open. |
| One colour | Pass: the fold is drawn as a cut-out triangle. |
| Reversed | Pass: Paper on Night, same geometry. |
| Lookalike | Not a known mark. Folded corners are a common "note" sign, so the P carries the distinctiveness. |

## Wordmark

"passnote" in Source Sans 3 Semibold, lowercase, outlined. The baseline aligns with the bottom of the bowl, and the mark's stem drops like the descender of the p.

## Files

- `logo/master-v5.vectorcraft`: artboards symbol-mono, symbol, symbol-reversed, horizontal, horizontal-reversed.
- `logo/export-v5/svg/` and `logo/export-v5/png/`.

Trademark clearance has not been done.

## Applied to the docs, README and pub.dev

| Where | File |
| --- | --- |
| Docs header logo | `docs/assets/logo.svg` (light), `docs/assets/logo-dark.svg` (dark) |
| Docs favicon | `docs/assets/favicon.svg`, switches colour with the system theme |
| Docs palette | `docs/stylesheets/passnote.css`: Ballpoint links on a near-white page (7.9:1); Fold links on Night (6.9:1) |
| README | `docs/assets/passnote-horizontal.svg`, with `passnote-horizontal-on-dark.svg` for dark mode (16.8:1 on GitHub's dark background) |
| pub.dev thumbnail | `packages/*/doc/passnote-logo.png`, the app icon |
