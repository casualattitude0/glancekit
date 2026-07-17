# Project Phase & Roadmap — Glancekit

_Analysis date: 2026-07-17 · Type: APP (macOS menu bar, SwiftUI + WidgetKit)_

## Evidence scorecard

| Field | Value |
|-------|-------|
| Stated phase | Released. README documents DMG install; `MARKETING_VERSION = 1.0.2` |
| Evidence phase | Feature-complete / Alpha, released publicly anyway |
| Confidence | High |
| Momentum | Accelerating. Every commit in the visible history is dated 2026-07-17, with 8 files still dirty |
| Stated vs revealed intent | README sells a platform ("fully extensible, with no limit on what gets added next"). The code is extensible by you, not by anyone else: 8 hardcoded `registry.register(...)` calls in `GlancekitApp.swift:22-29`, no dynamic discovery, no external bundle loading. `PLUGIN_CONTRACT.md` is addressed to AI sub-agents, not third-party developers |

**Evidence for placement:**

- All 8 glances are finished against real data sources. Zero `TODO`/`FIXME`/`HACK` across 7,986 lines of Swift, which is not normal and is worth saying out loud.
- Real persistence (`PluginRegistry`, 25+ namespaced `UserDefaults` keys), real auth (`GitHubAccount` + `CredentialStore`), real network layer (`NetworkClient`).
- Distribution exists and works: `make-dmg.sh`, `scripts/install.sh`, and `UpdateChecker` polling GitHub releases.
- No crash reporting anywhere. The APP ladder puts crash reporting at Beta, so this cannot claim Beta.
- No tests. Not a thin suite, none: no test target, no test files.

**Contradictions / blockers:**

- **Ad-hoc signature is one root cause with three symptoms.** `CODE_SIGN_IDENTITY = "-"` in both `make-dmg.sh:50` and the project. `codesign -dv /Applications/Glancekit.app` reports `Signature=adhoc`, `TeamIdentifier=not set`. That single fact blocks notarization (every stranger hits Gatekeeper), blocks App Groups (your own note at `scripts/install.sh:75` says so), and probably blocks login-item registration. Blocks Beta and Launch.
- **A dead entitlement is still declared.** `Glancekit/Glancekit.entitlements` asks for `group.com.glancekit`. `scripts/install.sh:75` says App Groups are impossible under ad-hoc signing. One of the two is wrong, and the script is the one that got tested.
- ~~**Two install scripts have diverged, and the root one is dangerous.**~~ Fixed 2026-07-17. The root `install.sh` did `rm -rf "$DEST"` before copying, which `scripts/install.sh:69` explains destroys placed widgets' saved config, because chronod prunes a widget instance whose appex disappears. Nothing referenced it except a README layout listing, so it was deleted rather than shimmed.
- **Tags and version disagree.** Tags stop at `v1.0.1`. The project says 1.0.2. So 1.0.2 shipped untagged, and there is no commit you can point at as "what 1.0.2 was."
- **`UpdateChecker.isNewer` is load-bearing and untested.** If it is wrong, every user silently stops receiving updates and nobody files a bug, because the failure mode is nothing happening.
- **No launch at login.** `INFOPLIST_KEY_LSUIElement = YES` (`project.pbxproj:283`) with zero hits for `SMAppService`, `ServiceManagement`, or `LSSharedFileList`. A menu-bar-only app that vanishes on reboot.

## Where it's going

A real app that strangers download and keep using. Not a portfolio piece, not a personal daily driver.

That destination is what makes the signing gap a blocker rather than a footnote. Signing cannot be solved with the certs on this machine: `security find-identity` shows an Apple Distribution cert for team `5X5B3H4UUK` (Buho Interactive Entertainment), which is a company team and not yours to use for an MIT project published under your own name. Notarization therefore waits on a personal Apple Developer enrollment ($99/yr). That is a purchase decision, not an engineering task, which is why it is not Phase 1.

## Roadmap

### Phase 1 — Survives the reboot  ← current focus

- **Goal:** Glancekit is in the menu bar after a restart, without the user doing anything.
- **Exit criterion:** Fresh install to `/Applications` via `scripts/install.sh`, flip the toggle, restart the Mac, and the icon is there. The toggle still reads on afterward, because it reads live system state rather than a saved bool.
- **Key work:**
  - A launch-at-login toggle in Settings, on the Glances page next to the update row.
  - Find out whether `SMAppService.mainApp.register()` works on an ad-hoc bundle with no team identifier. This is the actual question.
  - If it does not, fall back to a user LaunchAgent. The main app is unsandboxed (`Glancekit.entitlements` declares only app-groups, no `com.apple.security.app-sandbox`), so it can write `~/Library/LaunchAgents`.
  - The toggle must never lie. Read status from the system on every appearance.
- **Dependencies:** None. `ServiceManagement` ships with macOS.
- **Rough effort:** ~1-3 days, most of it in the reboot loop rather than the code.
- **Risks:** The tempting shortcut is a `UserDefaults` bool. It produces a toggle that flips on, does nothing, and still says on. See the Next Slice section.

### Phase 2 — Opens without the right-click dance

- **Goal:** A stranger double-clicks the DMG, drags to Applications, double-clicks the app, and it opens.
- **Exit criterion:** `spctl -a -vvv /Applications/Glancekit.app` says `accepted source=Notarized Developer ID`, and the README paragraph telling people to right-click-Open gets deleted.
- **Key work:** Personal Apple Developer enrollment. Developer ID Application cert. `notarytool store-credentials` (there is no profile today; `notarytool history` errors). Notarize and staple in `make-dmg.sh`. Then delete the `group.com.glancekit` entitlement or make it real, whichever the new signature allows.
- **Dependencies:** $99/yr and Apple's enrollment turnaround. This phase can block on someone who is not you.
- **Rough effort:** ~2-3 days of work spread across however long enrollment takes.
- **Risks:** Hardened runtime is already on (`flags=0x10002(adhoc,runtime)`), so this is less work than it looks. The risk is calendar, not code. Also: whatever Phase 1 concludes about ad-hoc login items may become moot here, and that is fine. Phase 1 buys a working feature now instead of a working feature after a purchase.

### Phase 3 — Every glance is one keypress away

- **Goal:** All 8 glances are bindable to a global hotkey, and a clash warns instead of silently stealing.
- **Exit criterion:** The Shortcuts page lists every registered glance. Binding ⌥1 to a second glance warns before committing.
- **Key work:** `ShortcutAction` is a hardcoded 3-case enum (`HotkeyCenter.swift:12-16`) sitting on top of machinery that is already generic: `ToolWindowManager.toggle(plugin:)` takes any `GlancePlugin`, and the `pluginID` → `registry.plugin(id:)` indirection at `GlancekitApp.swift:48` was built for N and is used by one. Also wire up `HotkeyCenter.conflictingAction(for:excluding:)` (`:151-153`), which is dead code whose docstring describes a warning UI that was designed and never built.
- **Dependencies:** None.
- **Rough effort:** ~1-2 days.
- **Risks:** Carbon hotkey IDs are currently derived from a fixed enum. Making them per-plugin means the id space has to survive a plugin being disabled and re-enabled, or bindings drift onto the wrong glance.

### Phase 4 — Doesn't rot silently

- **Goal:** The logic that fails invisibly has tests.
- **Exit criterion:** `xcodebuild test` is green and runs on push.
- **Key work:** A test target, then tests for the pure logic that has no UI to reveal a bug: `UpdateChecker.isNewer`/`normalize`, `GlobalShortcut` Codable round-trip including the `"cleared"` sentinel, `JSONPath`, `ColorHex`, `QuickSwitchStore.ring(in:)`.
- **Dependencies:** None.
- **Rough effort:** ~2-3 days.
- **Risks:** Aiming at UI tests first. The bugs that hurt here are in pure functions, and those are cheap to cover.

## Cross-cutting ideas & risks

All six items in this section were cleared on 2026-07-17, in one pass, verified by an integration build. Kept as a log rather than deleted, because three of them record a decision rather than a cleanup.

- **Root `install.sh`: deleted.** It contradicted `scripts/install.sh` and destroyed placed widgets' config. Nothing referenced it but a README layout listing, so a shim would have been dead weight (it would have forwarded `--login`/`--no-launch`, which `scripts/install.sh` does not accept). README now documents `scripts/install.sh`, states that it deletes rather than unregisters rival copies (it `rm -rf`s any `*/Glancekit.app` it finds, including `~/Downloads` and mounted volumes), and states that it builds Debug rather than Release.
- **Refresh at launch: decided, loops now start at launch.** `coordinator.start()` moved from the popover's `.onAppear` to `MenuBarLabelView.onAppear` (`MenuBarLabelView.swift:21`), the one view `MenuBarExtra` builds eagerly. The owner was told the cost (Weather/Stocks/GitHub poll from boot for a surface nobody is looking at, since the menu bar has been a static glyph since `7ae0a26` and widgets fetch in their own process) and chose it anyway. `start()` was already idempotent: it delegates to `reconcile()`, which spawns only `where tasks[plugin.id] == nil`.
- **Stale scaffolding comment: gone.** `GlancekitApp.swift:14-21` described a "Stage 1 / Stage 2 sub-agents / Stage 3" process and listed fake example registrations. Replaced with two lines on how registration order relates to popover order.
- **`UpdateChecker` download progress: built for real.** `URLSession.download(from:)` replaced with a `URLSessionDownloadDelegate`. The payload changed shape to `Phase.downloading(progress: Double?)`, where `nil` means indeterminate, which is what a server sending no Content-Length actually gives you. Reporting 0 there would have recreated the same lie. Settings renders a determinate bar or a spinner accordingly.
- **`RefreshCoordinator.stop()`: deleted.** Confirmed dead by grep. Consequence worth knowing: nothing can now pause the loops, which is fine today but is where `stop()` earns its way back if "pause refresh on battery" ever comes up.
- **Colors key drift: migrated.** `glancekit.colorpicker.recent`/`.uppercase` moved to `glancekit.colors.*`, guarded by `glancekit.migration.colorkeys`. Favorites were never affected; they already lived at `glancekit.colors.favorites` (`ColorFavoritesStore.swift:14`), so only two keys drifted, one of them user-generated. The old key wins until the flag latches, and the flag latches before the old keys are dropped, so every kill point leaves either a redoable state or a harmless orphan.

## Open questions

- Will you enroll a personal Apple Developer account? Phase 2 is entirely gated on that answer, and Phase 1 is deliberately built to not care.
- Is the README's extensibility pitch a promise to third parties or a description of how you work with agents? If the former, dynamic plugin loading is a phase nobody has scheduled. If the latter, the README oversells and should say so.
- ~~Should background refresh run from launch, or stay lazy until first open?~~ Answered 2026-07-17: from launch. See cross-cutting.

## Next Slice

**Recommended:** Launch at login, on the build you actually ship
**Score:** 10/10
**Hypothesis:** If we register a login item from the ad-hoc-signed `/Applications` build and reboot, we learn whether macOS permits login-item registration without a team identifier. If it works, launch at login ships now and the $99 question stays about notarization only. If it fails, we learn that the ad-hoc signature costs more than the Gatekeeper warning, which moves enrollment from "someday" to "next", and we ship the LaunchAgent fallback regardless.

### Candidate comparison

```
Next Slice Candidates
═══════════════════════════════════════════════════════════════════
Candidate            Valid  Feasib  Signal  Depend  Scope   Total   Rank
───────────────────  ─────  ──────  ──────  ──────  ─────   ─────   ────
A: SMAppService,       2/2    2/2     2/2     2/2     2/2    10/10    1
   probe then fall
   back
B: LaunchAgent         0/2    2/2     2/2     2/2     2/2     8/10    2
   plist, skip the
   question
C: Developer ID        2/2    0/2     2/2     0/2     1/2     5/10    3
   first, then
   SMAppService
═══════════════════════════════════════════════════════════════════

RECOMMENDED: Candidate A — it delivers the feature either way, and on the way
it answers the one question that gates the rest of the roadmap. The score is
high because the slice is small and the signal is a reboot, not because it is
ambitious.

Rejected:
- B: Ships the feature and learns nothing. It also picks the noisier mechanism
  by default: on macOS 13+ writing ~/Library/LaunchAgents triggers a "Glancekit
  added a login item" notification, which reads like malware. Take that cost
  only if forced.
- C: Feasibility 0 and dependency 0. Enrollment involves payment and Apple's
  turnaround, so the slice can sit blocked for days on someone who is not you.
  Phase 1 exists precisely to not be blocked on this.
```

### What to build

- A launch-at-login toggle in Settings, on the Glances page.
- `SMAppService.mainApp.register()` / `.unregister()` behind it.
- Live status reads via `SMAppService.mainApp.status`, on every appearance.
- Honest error surfacing when registration fails, including the case where macOS accepts the call and does nothing.
- The LaunchAgent fallback, but only if the probe fails.

### What to fake (placeholder OK)

- Error copy wording. Get the failure visible first, make it read well later.
- Toggle placement. Glances page is fine; it does not need its own settings page.

### What must be real (do NOT fake)

- **The build under test.** It must be `/Applications/Glancekit.app` installed via `scripts/install.sh`, ad-hoc signed, exactly what ships. An Xcode run build is signed with an Apple Development cert and has a team identifier, so it would register fine and teach you nothing. This is the whole slice. Per CLAUDE.md, never `open` a build product.
- **The reboot.** Not logout, not relaunch. Registration can succeed and still not survive a restart.
- **The status read.** A `UserDefaults` bool cannot distinguish "registered" from "we asked and macOS ignored us", which is the exact failure this slice is hunting.

### Success criteria

- Toggle on, restart the Mac, Glancekit is in the menu bar without being asked.
- Glancekit appears in System Settings ▸ General ▸ Login Items.
- Toggle still reads on after the restart.
- Toggle off, restart, it does not appear.

### Failure looks like

- `register()` throws, most likely `SMAppServiceErrorDomain` code 1 or `NSCocoaErrorDomain` 4099. Clean signal: ad-hoc is refused, go to the fallback.
- `register()` returns without throwing, `status` says `.enabled`, and the app does not start after reboot. This is the nasty one and the reason the reboot is non-negotiable.
- It works. Then the ad-hoc signature is cheaper than assumed, and Phase 2 is only about Gatekeeper.

### Build time estimate

~1-3 days. The code is small. The reboot loop is the cost.

### Dependencies

None.
