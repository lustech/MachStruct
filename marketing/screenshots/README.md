# MachStruct — App Store Screenshots

App Store Connect requires screenshots for **macOS** at one of these display
sizes (you must provide at least one of the listed sizes; uploading both is
strongly recommended for sharper Retina rendering on every device):

| Display | Size (px)   | Notes |
|---------|-------------|-------|
| 13"     | 1280 × 800  | Required if the app supports 13" Macs |
| 15"     | 1440 × 900  | Required if the app supports 15" Macs |
| 16"     | 2560 × 1600 | Optional — Retina, sharpest |

Apple's current minimum is **3 screenshots** per uploaded size; the maximum
is 10. Aim for **at least 5** to fill the listing carousel.

## Suggested shot list

1. **Tree view, large JSON file** — show a deep document expanded with
   colourised type badges. Highlights speed (status bar shows node count
   in millions) and the visual hierarchy.
2. **Search in action** — toolbar with active query, prev/next navigation,
   matches highlighted in the tree.
3. **Raw view with syntax highlighting** — pretty-printed JSON with a
   bookmark gutter visible.
4. **CSV table view + stats panel** — a real-world CSV with the per-column
   statistics drawer open on the right.
5. **Command palette (⇧⌘P)** — palette open with a query like "expand"
   showing fuzzy results.
6. **Scalar inspector** — popover on a base64 or timestamp value showing
   the decoded payload / formatted date.
7. **Welcome window** — drop zone, paste box, recent files. Pairs nicely
   with marketing copy.

## Notes

- **No window chrome from another window theme.** Use the default macOS
  window appearance; do not paste the app onto a marketing background that
  looks like a screenshot of a different OS.
- **Prefer real data** over `lorem ipsum`. The samples in `marketing/samples/`
  (or the README screenshot fixtures from commit 5b5b05d) are good starting
  points.
- Use **dark mode** for at least one screenshot — many App Store browsers
  view at night and dark mode is one of MachStruct's polished surfaces.
- Save as PNG (App Store rejects compressed JPEGs in many cases). Strip
  metadata to avoid leaking author info.
- Keep file names ordered: `01-tree.png`, `02-search.png`, ... — Apple
  displays them in upload order.
