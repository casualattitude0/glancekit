# design-sync notes — @glancekit/design-system

This design system is a **web (React/CSS) mirror of the Glancekit macOS SwiftUI
app**, authored specifically for Claude Design. The SwiftUI app itself is not
syncable (native platform, no web bundle); this package captures its visual
language so the design agent builds on-brand.

## Build

- The DS package lives in `design-system/` (a subfolder of the SwiftUI repo,
  kept out of the Xcode build — it sits at repo root, not inside the
  `Glancekit/` synchronized group).
- Package manager: **pnpm**. Install/build must set `COREPACK_ENABLE_STRICT=0`
  (corepack tries to self-provision a pinned pnpm otherwise and fails).
  - Install: `cd design-system && COREPACK_ENABLE_STRICT=0 pnpm install`
  - Build:   `cd design-system && COREPACK_ENABLE_STRICT=0 pnpm run build`
- Build tool is **tsup** → emits `dist/index.js` (ESM) + `dist/index.d.ts`.
- Converter entry: `--entry ./design-system/dist/index.js`,
  `--node-modules ./design-system/node_modules`.

## Styling

- **One self-contained stylesheet**: `design-system/src/styles.css`. Tokens
  (`:root` custom properties, light + `[data-theme="dark"]` + prefers-color-scheme
  dark) are inlined at the TOP, component classes below. `cfg.cssEntry` points
  at it; the converter appends it into `_ds_bundle.css`.
- There is deliberately **no separate `tokens.css`** and no `@import`:
  `copyTokens` only resolves a node_modules tokens package, and the package
  shape doesn't auto-detect a src token file — an `@import "./tokens.css"` would
  dangle once styles.css is appended into `_ds_bundle.css` at the bundle root.
  Keep tokens inlined in styles.css.
- Fonts: system stack only (`-apple-system`, `system-ui`, `ui-monospace`…). No
  shipped webfonts by design — `[FONT_MISSING]` should not fire.

## Re-sync risks

- Tokens live inside `styles.css` (not a `tokens/` folder). A future maintainer
  reaching for `cfg.tokensGlob`/`tokensPkg` will not work here without a real
  node_modules tokens package — edit `styles.css` instead.
- This DS mirrors the SwiftUI app by hand; it does not track it automatically.
  If the app's look changes materially, update `design-system/src/*` to match —
  nothing catches drift.
