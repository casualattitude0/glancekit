# Implementation Handoff: Launch at Login

Roadmap: [PROJECT_PHASE.md](PROJECT_PHASE.md) § Next Slice
Branch: `develop`
Date: 2026-07-17
Type: APP (macOS menu bar, SwiftUI)

## 1. Build Target

> Glancekit starts itself at login on the ad-hoc-signed build that actually ships, controlled by one Settings toggle that reports what the system really thinks rather than what we saved.

**Soul of this slice:** the toggle never lies. A switch that says on while the app is dead after reboot is worse than no switch, because it converts a missing feature into a bug the user cannot diagnose.

## 2. Scope

### In Scope

- [ ] **MUST** — A launch-at-login toggle on the Settings ▸ Glances page.
- [ ] **MUST** — Registration and unregistration wired to the toggle.
- [ ] **MUST** — Toggle state read from live system status every time the page appears, never from a stored bool.
- [ ] **MUST** — A visible, specific message when registration fails. Not silence, not a generic "something went wrong".
- [ ] **MUST** — Verified by reboot on `/Applications/Glancekit.app` installed via `scripts/install.sh`.
- [ ] **SHOULD** — Fallback mechanism, if and only if the probe proves the primary route does not work on an ad-hoc bundle. Do not build this speculatively.
- [ ] **COULD** — A link to System Settings ▸ General ▸ Login Items when registration is blocked by the user rather than by the signature.

### Out of Scope

- Notarization and Developer ID. That is Phase 2 and gated on an enrollment decision. This slice exists to not wait for it.
- Deleting or fixing the `group.com.glancekit` entitlement. Related root cause, separate change, do not entangle them.
- Reconciling the two `install.sh` scripts. Already done on 2026-07-17: the root script is deleted, `scripts/install.sh` is the only one left.
- Starting refresh loops at launch. `coordinator.start()` staying in the popover's `.onAppear` is a deliberate open question in the roadmap. Do not quietly resolve it here.
- Any change to `ShortcutAction` or the hotkey system. Phase 3.
- Onboarding copy about login items.

### Placeholder OK

- Error message wording. Ship it blunt and readable, polish later.
- Toggle label and help text.
- Toggle position within the Glances page.

## 3. Experience Requirements

| User Action | Expected Response | Timing | Quality Target |
|-------------|-------------------|--------|----------------|
| Opens Settings ▸ Glances | Toggle reflects real current registration state | On appear, no visible lag | Correct after an external change (user removed it in System Settings) without relaunching Glancekit |
| Flips toggle on | Switch moves and stays on | Immediate | No modal, no restart prompt, no confirmation dialog |
| Flips toggle on, registration fails | Switch returns to off, message appears naming what happened | Under 1s | The user can tell it failed and roughly why. A switch that stays on after a failure is a defect |
| Restarts the Mac with toggle on | Glancekit icon is in the menu bar | Within the normal login item window | User did nothing. No Dock bounce, no window, no onboarding re-shown |
| Reopens Settings after that restart | Toggle still reads on | On appear | State survived a full boot, read from the system |
| Flips toggle off, restarts | Glancekit does not appear | — | Also gone from System Settings ▸ Login Items |
| Removes Glancekit in System Settings, reopens Glancekit's Settings | Toggle reads off | On appear | Proves the read is live, not cached |

## 4. System Requirements

| System | What It Does | Exists? | Notes |
|--------|-------------|---------|-------|
| `ServiceManagement` / `SMAppService` | Registers the app as a login item | No | Zero hits for `SMAppService`, `ServiceManagement`, `LSSharedFileList` anywhere in the repo. Ships with macOS, deployment target is 14.0 so the API is available |
| Settings ▸ Glances page | Hosts the toggle | Yes | `SettingsView.swift:111`. Already has an `updateRow` with a similar shape to copy |
| Ad-hoc code signature | The constraint under test | Yes | `CODE_SIGN_IDENTITY = "-"`, `TeamIdentifier=not set`. This is the thing the slice is probing |
| Unsandboxed main app | Enables the LaunchAgent fallback | Yes | `Glancekit.entitlements` declares only app-groups, no `com.apple.security.app-sandbox`, so `~/Library/LaunchAgents` is writable |
| `scripts/install.sh` | Produces the build under test | Yes | The only sanctioned route to a smoke-testable `/Applications` install, per CLAUDE.md. It is now also the only install script; the root one was deleted |
| Persistence | Remembering the setting | **No, and must stay No** | The system is the source of truth. Adding a `glancekit.*` key for this is the primary failure mode of this slice |

## 5. Asset Requirements

| Asset | Real or Placeholder | Spec |
|-------|-------------------|------|
| Toggle label + help text | Placeholder OK | Plain wording, match the tone already on the Glances page |
| Failure message copy | Placeholder OK | Must name the failure. Blunt beats polished for now |
| SF Symbol for the row | Placeholder OK | Anything sensible. `power` or `arrow.right.circle` |

## 6. Acceptance Criteria

### Engineering Done

- [ ] Builds with `xcodebuild -scheme Glancekit -derivedDataPath /private/tmp/gkdd` and no new warnings. Never a bare `xcodebuild` (CLAUDE.md).
- [ ] Toggle appears on Settings ▸ Glances and moves when clicked.
- [ ] Registration and unregistration both invoked and their outcomes handled.
- [ ] Every interaction in §3 works.
- [ ] No new `UserDefaults` key was added for login state.

### Experience Done

- [ ] Installed via `scripts/install.sh`, toggled on, **Mac restarted**, Glancekit is in the menu bar.
- [ ] After that restart, the toggle still reads on.
- [ ] Glancekit is listed in System Settings ▸ General ▸ Login Items.
- [ ] Removing it there and reopening Glancekit's Settings shows the toggle off, with no relaunch.
- [ ] Toggled off, restarted, it does not appear.
- [ ] Soul check: at no point does the toggle show a state the system disagrees with.

### NOT Done Until

- [ ] A real reboot happened. Logout/login does not count. Quitting and relaunching does not count.
- [ ] The tested build was `/Applications/Glancekit.app`, ad-hoc, from `scripts/install.sh`. Not an Xcode run build, which carries a team identifier and would pass while shipping broken.
- [ ] The outcome is written down in `PROJECT_PHASE.md`: did ad-hoc registration work, yes or no. That answer is the deliverable, as much as the toggle is.

## 7. Known Risks

| Risk | Impact | Tempting Shortcut | Why It Kills the Slice |
|------|--------|-------------------|------------------------|
| Toggle backed by a saved bool | Critical | Store `glancekit.launchAtLogin`, render the switch from it | This is exactly the bug the slice is hunting. A bool cannot tell "registered" from "we asked and macOS ignored us". Every symptom disappears and the defect ships |
| Testing on an Xcode build | Critical | Hit Run, flip the toggle, it works, call it done | Xcode builds are signed with an Apple Development cert and have a team identifier. The shipped build has neither. The test would pass and prove nothing about what users get. CLAUDE.md also forbids `open` on a build product because the appex shadows `/Applications` |
| Logout instead of reboot | High | "Logout is the same thing and takes 20 seconds" | Registration can survive a logout and not a cold boot. The one failure mode worth catching is the one where the API says `.enabled` and the app never starts |
| `register()` succeeding silently while doing nothing | High | Trust the return value and skip the reboot | The nastiest possible outcome and the reason the reboot is a MUST rather than a SHOULD |
| Building the LaunchAgent fallback up front | Medium | "We'll probably need it, write both" | On macOS 13+ writing `~/Library/LaunchAgents` fires a "Glancekit added a login item" notification that reads like malware. Only pay that if the primary route is actually refused. Building both also destroys the signal about which one was necessary |
| Scope creep into signing | Medium | "While I'm here, let me fix the dead entitlement / add notarization" | Phase 2 is deliberately gated on a purchase decision. Entangling them means this feature blocks on $99 |
| Fixing the popover-lazy-refresh thing | Medium | "The app runs from boot now, so refresh should start at boot" | It is a real question and it is listed as open. Answering it inside this slice hides a behavior change inside a login-item PR |

## 8. Test Hooks

| What to Test | How to Test | Pass Criteria |
|-------------|-------------|---------------|
| Registration on the shipped build | `scripts/install.sh`, open Settings ▸ Glances, flip on | Switch stays on, no error surfaced |
| It actually starts at login | `sudo reboot`, log in, wait, do nothing | Glancekit icon is in the menu bar |
| The system agrees | System Settings ▸ General ▸ Login Items | Glancekit is listed |
| Status is a live read | Remove it in System Settings, then reopen Glancekit's Settings without relaunching | Toggle reads off |
| Unregistration | Flip off, reboot | Icon absent, and gone from Login Items |
| Failure path is visible | If `register()` throws, read the error | Message names the domain and code, switch snapped back to off |
| The verdict is recorded | Read `PROJECT_PHASE.md` | Phase 1 states plainly whether ad-hoc registration worked |
| No stored state crept in | `grep -rn "launchAtLogin\|loginItem" --include="*.swift" .` and check every `UserDefaults` hit | No persistence key for login state |
