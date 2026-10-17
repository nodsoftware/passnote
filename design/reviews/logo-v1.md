# Logo review, v1

## Directions

| Direction | Verdict |
| --- | --- |
| D1: ring of four segments around a dot (devices around shared data) | Dropped: reads as a lifebuoy or target icon. |
| D2: a C wrapped around a keyhole (*cum clave*, "with a key") | Chosen. |

D2 v1 had a small keyhole that became a bar at 16 px; v2 enlarges it by about
30 %.

## Tests

| Test | Result |
| --- | --- |
| 16 / 32 / 48 px | Pass. C clear at 16 px; keyhole clear from 32 px, a soft slot at 16 px. Use the mono symbol for 16 px favicons. |
| One colour | Pass: `symbol-mono`, `horizontal-mono`. |
| Reversed | Pass. White on ink looks slightly heavier; acceptable at v1, revisit for a thinner reversed cut. |
| Lookalike | Generic keyhole-in-circle icons exist; the open C and flat terminals set it apart. Legal clearance still needed. |
| Contrast | Ink on white 17.2:1; key green `#0A7B63` on white 5.2:1; `#3FD3A3` on ink 9.0:1. |

## Construction

512 px artboard, centre (256, 256). Ring: outer radius 208, inner 136, opening
cut by two horizontals at y = 212 and y = 300. Keyhole: head radius 48 at
(256, 232), stem from 36 px to 68 px wide, base at y = 336.

## Palette

| Name | Hex | Use |
| --- | --- | --- |
| Ink | `#0F1E1C` | Mark, wordmark, dark backgrounds |
| Key green | `#0A7B63` | Keyhole on light backgrounds |
| Key green light | `#3FD3A3` | Keyhole on ink |
