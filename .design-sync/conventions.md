# Glancekit design system — build conventions

A macOS-native, "glanceable data" system: Apple system font, adaptive light/dark,
semantic status colours, tabular numerics, and calm System-Settings surfaces.
Mirrors the Glancekit macOS app.

## Setup — no provider, one stylesheet

There is **no context provider and no wrapper to mount.** Every component styles
itself. Do two things and components render on-brand:

1. Link the single stylesheet once: `<link rel="stylesheet" href="styles.css">`.
   It defines the design tokens (as CSS custom properties) and every component
   class. There is no separate tokens file to import — tokens live at the top of
   `styles.css`.
2. Theme is automatic. Components adapt to `prefers-color-scheme`. To force a
   theme, set `data-theme="light"` or `data-theme="dark"` on `:root` (or any
   ancestor) — that overrides the system preference.

## Styling idiom — props for components, tokens for your own glue

This is **not** a utility-class system. Do not invent class names.

- **Style components through their props/variants**, never by adding classes:
  `<Button variant="primary" size="large">`, `<Badge tone="positive">`,
  `<Stat trend="up">`, `<SettingsRow fillControl>`.
- **Style your own layout glue with the design tokens** (CSS custom properties),
  so it matches the components. Real names, all defined in `styles.css`:
  - Spacing: `--gk-space-3xs|2xs|xs|sm|md|lg|xl|2xl` (3 · 4 · 6 · 8 · 12 · 14 · 20 · 24 px)
  - Radii: `--gk-radius-sm|md|lg|xl|2xl|pill` (4 · 6 · 8 · 12 · 14 · 999)
  - Text colour: `--gk-label` (primary), `--gk-label-secondary`, `--gk-label-tertiary`
  - Surfaces: `--gk-surface` (cards), `--gk-bg`, `--gk-border`, `--gk-separator`
  - Accent + status: `--gk-accent`, `--gk-green`, `--gk-red`, `--gk-orange`
    (each has a `-soft` translucent fill, e.g. `--gk-green-soft`)
  - Type: `--gk-font-sans`, `--gk-font-mono`, sizes `--gk-text-caption`
    (11) · `--gk-text-body` (13) · `--gk-text-headline` (13, semibold) ·
    `--gk-text-title` (17) · `--gk-text-largetitle` (26); weights
    `--gk-weight-regular|medium|semibold|bold`.
- **Numbers use tabular figures.** For any changing numeric readout, prefer the
  `Stat` component; if you render digits yourself, add
  `font-variant-numeric: tabular-nums` so values don't jitter as they update.

## Where the truth lives

- `styles.css` — tokens (top) + all component classes. Read it before styling.
- `components/<Name>/<Name>.d.ts` — the exact props for each component.
- `components/<Name>/<Name>.prompt.md` — per-component usage.

## Idiomatic snippet

A glance surface, composed from library components with token-styled glue:

```tsx
import { GlanceCard, Stat, Badge } from "@glancekit/design-system";

<GlanceCard title="MARKETS" icon="📈">
  <div style={{ display: "flex", alignItems: "center",
                justifyContent: "space-between", gap: "var(--gk-space-md)" }}>
    <Stat label="AAPL" value="$182.40" delta="1.2%" trend="up" />
    <Badge tone="positive" dot>Live</Badge>
  </div>
</GlanceCard>
```

Settings surfaces follow the macOS idiom: group rows in a `Card` (bordered) or
`SettingsGroup` (borderless), one `SettingsRow` per setting, control on the
right (`Switch`, `SegmentedControl`, `Button`). Keep one primary `Button` per view.
