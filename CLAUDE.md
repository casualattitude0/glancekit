# Glancekit — project rules

## Never build into the default DerivedData

Always pass an explicit build location outside the Spotlight index:

```sh
xcodebuild -scheme Glancekit -derivedDataPath /private/tmp/gkdd ...
```

Never run a bare `xcodebuild`/`swift build` that lands in
`~/Library/Developer/Xcode/DerivedData`.

**Why:** Launchpad and the Applications gallery list apps from the **Spotlight
index**, not LaunchServices. `~/Library/Developer/Xcode/DerivedData` is indexed,
so every build there puts a second "Glancekit" icon in Launchpad alongside
`/Applications/Glancekit.app` (same version, same bundle id
`com.glancekit.Glancekit`). `/private/tmp` is **not** indexed — verified by probe
on 2026-07-17 — so a build there never shows up. The stale
`/private/var/folders/.../tmp.*` copies in `lsregister -dump` prove the same
point: registered, but invisible to Launchpad.

## Never `open` a build product

Smoke-test only `/Applications/Glancekit.app`, installed via `scripts/install.sh`.
Opening a DerivedData/temp build re-registers its widget appex, which then
**shadows** the /Applications one and silently serves stale widgets. That
shadowing is a real bug, not just a cosmetic duplicate.

## Checking for duplicates

`mdfind "kMDItemFSName == 'Glancekit.app'"` — this predicts what Launchpad shows.
`lsregister -dump` does **not**; it lists many registered copies that never appear.

## Two "fixes" that do not work — do not retry

- **`lsregister -u <path>` alone.** The bundle is still on disk and indexed, so
  LaunchServices rescans and re-adds it within seconds-to-minutes. Re-checking
  the dump immediately after shows it "gone" and is misleading.
- **`.metadata_never_index` inside DerivedData.** Does nothing; that marker is
  only honored at volume roots. Probed and disproved 2026-07-17.

Deleting the DerivedData bundle is symptom-treatment: every build recreates it.
Fix the build location instead.
