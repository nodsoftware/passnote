# Logo v3: Cloister

Renamed from Conclave after a name check found a US registration for
CONCLAVE covering SDKs (No. 6206970, 2020) and two encryption products
using the name.

## Name

A cloister is the enclosed walk of a monastery: a shared space only members
enter. It keeps the closed-room idea of a conclave without the collision.

| Candidate | pub.dev | Software uses found | Verdict |
| --- | --- | --- | --- |
| cloister | free | none found | **Chosen** |
| hortus (enclosed garden) | free | none found | Backup; Latin, less obvious |
| cenacle (upper room) | free | none found | Backup; hard to spell |
| covey (small group) | free | "Cove" encrypted locker is close | Dropped |
| sanctum | free | Laravel Sanctum (auth) | Dropped |

This is a web search, not a clearance. Search EUIPO (TMview) and the USPTO
in class 9 before publishing.

## Directions

| Direction | Verdict |
| --- | --- |
| A: arcade of three pointed arches | Dropped: reads as a comb or the letter m |
| B: plan view, quatrefoil garth | Dropped: reads as a flower; close to a fashion monogram |
| C: plan view, arcaded garth | Dropped: reads as a gear |
| E: two-light Gothic window with oculus | **Chosen** |

Two lights under one arch, joined by the round window above: separate
devices, one shared space.

## Construction (512 grid)

- Outer arch: x 104–408, springing y 262, radius 236, apex y 41.5, base y 468.
- Wall 36, mullion 26, sill 36.
- Lights: springing y 336, equilateral heads (radius 103).
- Oculus: centre (256, 178), radius 50.
- Wordmark: "cloister", Source Serif 4 Regular 236 pt, outlined, baseline
  aligned with the base of the window.

## Palette

| Name | Hex | Use |
| --- | --- | --- |
| Garth green | `#1F5C46` | Mark on light, app icon background |
| Ink | `#15201B` | Wordmark, dark background |
| Parchment | `#F2E8DC` | Mark and wordmark on dark |
| Sage | `#8CC7A6` | Links on dark (docs) |

## Tests

| Test | Result |
| --- | --- |
| 16 px | Pass: arch, both lights and oculus read; mullion greys out |
| 32 px | Pass |
| One colour | Pass (`symbol-mono`) |
| Reversed | Pass: parchment on ink 13.8:1, white on green 7.8:1 |
| Blur | Pass: silhouette distinct |
| Contrast | Green on white 7.8:1; green on ink 2.1:1, so never use green on ink |
| Lookalike | Generic church-window icons exist; no known logo matches this construction |
