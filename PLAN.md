# Development log

How the app was built and what each stage verified, in order. [SPEC.md](SPEC.md)
is the design source of truth; this records the findings that shaped it —
several of which contradicted the documentation they came from.

**Never assume hardware.** This app ships to Macs the developer cannot test. Fan count, RPM ranges, and sensor names come from the system or the code degrades visibly. See SPEC.md "Portability rule".

## Phase 0 — Scaffold ✅ DONE (2026-08-29)

Built with **Swift Package Manager** (kept deliberately over Xcode/XcodeGen — see SPEC.md "Project structure & build"). Verified on an M4 Pro MacBook Pro:

- `Package.swift`: four targets (SMCKit, MacFanSpeed, FanHelper, fanctl), macOS 14, Swift 5 language mode.
- `Resources/Info.plist` (`LSUIElement = YES`, bundle id `io.github.bradr23.MacFanSpeed`), `scripts/build.sh`, `scripts/run.sh`.
- Stubs: app shows a `MenuBarExtra` labelled `--° ----`; `fanctl version` and `FanHelper` print versions; SMCKit exposes a version constant.
- **Accepted**: clean `scripts/build.sh release` builds and ad-hoc signs the bundle; `MFS_SELFTEST=1 …/MacFanSpeed` prints `selftest.result: PASS`; placeholder confirmed visible in the menu bar by screenshot.

## Phase 1 — Read-only low level ✅ DONE (2026-08-29)

SMCKit reads the SMC and the HID temperature sensors; `fanctl` exposes them. No writes anywhere.

- `SMCConnection` — IOKit `AppleSMC` access with runtime struct-layout verification, key info + read, and decoding for `ui8/ui16/ui32/si8/flt/fpe2/sp78`.
- `CIOHIDShim` — a small C target declaring the private IOKit HID symbols, with inline wrappers so CoreFoundation ownership stays in C (Swift cannot call `CFRelease`).
- `FanReader`, `TemperatureReader` with the four-tier classifier, `SystemMonitor` façade.
- `fanctl fans | temps [--cpu|--dump] | watch | key <KEY> | version`.
- 18 unit tests over the hardware-independent logic (classification, tier preference, fan range maths, fanless path), runnable on any Mac.

**Two assumptions turned out to be wrong, and both are now corrected in SPEC.md:**

1. **`SMCParamStruct` is 80 bytes, but Swift laid it out as 76.** Swift omits C's trailing padding for nested structs. `SMCKeyInfoData` now carries explicit reserved bytes, and the layout is verified at construction — the guard caught this before a single malformed request reached the kernel.
2. **`F{i}Md` is not 0 = auto / 1 = forced on Apple Silicon.** An untouched M4 Pro reports **3**. The old acceptance criterion and safety rule ("verify `F0Md` reads 0") were unsatisfiable on this hardware and would have invited a bogus write. `Fan.modeRaw` now reports the value verbatim.

**Also observed**: this M4 Pro exposes **no `ACC MTR Temp` sensors at all** — only `PMU tdie1`–`tdie14` (tier 2). The tiered fallback is load-bearing. `PMU tcal` reads ~15 °C high and is excluded. Sensor names repeat across services and are deduplicated by taking the hottest.

- **Accepted**: `fanctl fans` shows 2 fans, min 2317 / max 7826 RPM; `fanctl temps --cpu` reports ~37 °C idle; under all-core load the hottest CPU climbed 36.7 → 42.0 °C monotonically over 45 s while **both fans stayed at 0 RPM** — a direct demonstration of the problem this app exists to solve. `swift test` passes 18/18.

## Phase 2 — Read-only menu bar app ✅ DONE (2026-08-29)

Live monitoring UI over the Phase 1 layer. Still no writes.

- `FanMonitor` — `@MainActor` observable with a 2 s poll loop on a serial background queue, a 300-sample ring buffer (10 minutes), temperature unit persistence, and menu bar formatting.
- Menu bar label `39° 0` in monospaced digits; temperature only on fanless Macs; `--°` when sensors are unreadable.
- Dropdown: CPU temperature with sensor name, one row per discovered fan showing its own min–max range, two Swift Charts sparklines, a locked `Auto` mode picker, and a °C/°F toggle.
- Poll timer registered in `.common` run loop mode, so readings keep updating while the dropdown is open.
- `SMCConnection` and `TemperatureReader` gained locks: reading a key is a size-then-read pair that must not interleave, which also made the types honestly `Sendable`.
- `MFS_PREVIEW=1` opens the dropdown in a floating window — the only way to inspect it here, since clicking a `MenuBarExtra` needs Accessibility permission.
- `MenuBarFormatter` holds the label formatting as pure functions, so the fanless and sensor-failure display paths are unit-tested even though they cannot be produced on this hardware. 29 tests total.

- **Accepted**: app reported 38.8 °C from `PMU tdie6` against `fanctl`'s 38.5 °C from the same sensor seconds later; the temperature chart shows a clear load bump (≈40 → 45 → 42 °C); `MFS_SELFTEST=1` passes with `readings: OK` and `polling: OK`.

**Memory**, measured twice because the first run was misleading. Holding the dropdown open for 12 minutes showed a steady ~217 KB/min climb, which looks like a leak. Re-running in the configuration users actually have — menu bar only, dropdown closed — showed the real behaviour over 15 minutes: flat at ~69 MB, a one-time jump to ~92 MB when SwiftUI first realises the dropdown view, a peak of 93 MB, then a **decline** to ~89 MB where it settled. Memory being returned rules out a leak; the drift is chart and view caching. If a future change makes this worth re-checking, soak with the dropdown *closed* — an open dropdown re-renders two charts every 2 s and is a worst case, not the norm.

A fan chart bug worth remembering: with fans stopped, the adaptive y-axis padded around a constant zero and rendered a **−1 rpm** gridline. Charts of physical quantities need an explicit lower limit, not just adaptive padding.

## Phase 3 — Privileged helper + manual control ✅ DONE (2026-08-29)

**Accepted: 7/7 on `sudo ./scripts/verify-fan-control.sh`**, plus the app's own control path verified separately. Fan control works on Mac16,8 / macOS 26.3.1.

| Check | Result |
|---|---|
| Direct SMC write (`fanctl set`) | fans reached 4528 rpm of 4520 requested |
| Release to automatic | mode back to baseline 3 |
| Daemon install + XPC | responding |
| Control through the daemon | 4527 rpm |
| Crash protection (`kill -9`) | **fans automatic 3 s after the client died** |
| Clamping | 99999 → 7826, the fan's own maximum |
| App manual control (`MFS_TEST_MANUAL=55`) | 0 → 5365 rpm of 5347 requested |
| App quit | daemon logged release in 3.0 s |

**Getting here took four rounds, and the failures were more instructive than the passes:**

1. **Every write refused with error 130.** A control experiment — writing a key *its own current value* — proved this was a lock rather than a bad value, which pointed at `thermalmonitord` rather than at our code. Without that step the obvious reading was "Apple blocked fan control".
2. **The unlock existed but the probe missed it.** `Ftst = 1` works, but the firmware yields somewhere in a window: the mode write landed at **5.3 s** against a fixed 5.0 s sleep. Retrying instead of guessing the moment is the whole difference.
3. **Two safety mechanisms defeated each other.** The disconnect handler and the watchdog both ran restore concurrently; one cleared `Ftst` while the other was still writing modes, so those writes failed for their entire retry window and the fans stayed forced past the recovery budget. All restore paths are now serialized on one queue.
4. **Control is asymmetric.** Writing mode 1 takes the fans; writing the old mode back does *not* return them — that write is refused even while unlocked. Only clearing `Ftst` hands control back. Retrying it cost 4 s per fan and produced errors for a write that could never land; removing it took crash recovery from 11 s to 3 s.

Two bugs that only the daemon's own logging caught: it once recorded a **baseline of 0** after starting mid-probe, and would have "restored" the fans to a value that was never automatic; and `fanctl auto` — a fresh process — captured the *forced* mode as its baseline and silently did nothing. Baselines are now only trusted when read with `Ftst` clear, and restore no longer depends on having one.

### Original checklist

**The failsafe was pulled forward from Phase 4.** SPEC.md safety rule 3 makes it mandatory, and Phase 3 is what makes manual control possible; shipping the two out of order would leave a window where fans could be held low with nothing watching the temperature. Phase 4 keeps presets, persistence and launch-at-login.

Built in this phase:
- `SMCConnection.writeFan(index:field:value:)` — the only write in the project. It builds the key itself from a fan index and a two-case enum, so naming an arbitrary SMC key is not expressible. Values are encoded from the type the SMC reports, not an assumed one.
- `FanController` — clamps to each fan's own range, and restores automatic control by writing back **the mode value each fan reported before anything was written**, never a hardcoded constant.
- `FanHelper` — root LaunchDaemon exposing only `setFan`, `setAllAuto`, `heartbeat`, `version`. Re-clamps independently. Reverts to automatic on watchdog timeout, client disconnect, SIGTERM/SIGINT and system sleep.
- `Failsafe` — trips at 95 °C or on lost temperature readings, releases below 85 °C with hysteresis. 11 unit tests.
- App: mode picker, per-fan sliders bounded by real hardware limits, link-fans toggle, 2 s heartbeat, helper-status banner carrying the exact install command, release-fans-on-quit.
- `fanctl probe-mode` (establishes mode semantics, always self-restoring), `set`, `auto`, and `helper-status` / `helper-set` / `helper-auto` so the daemon and its watchdog are testable without the GUI.
- `scripts/install-helper.sh`, `uninstall-helper.sh` (releases fans before removing anything), `verify-fan-control.sh`.

Verified without root: all three write commands refuse with a clear message; the helper refuses to run as non-root; `helper-status` correctly reports "not installed"; the dropdown shows the install banner with the Mode picker disabled; 38 tests pass; fans remain untouched at their mode-3 baseline.

### Original checklist
- SMC **writes** in SMCKit, behind an API that takes only (fan index, RPM) and clamps internally — structurally unable to write other keys.
- **First, establish the fan mode values empirically** (Phase 1 proved the documented 0/1 semantics are wrong here — an untouched M4 Pro reads 3). Record `fanctl fans` output *before* writing; write a forced mode; observe what `F{i}Md` reads back and whether RPM actually follows `F{i}Tg`; then record both the automatic baseline and the forced value in SPEC.md. Restoring automatic means writing the recorded baseline, **never 0**.
- Prove writes via `sudo fanctl set 3000` / `sudo fanctl auto`. **End every session with `sudo fanctl auto` and confirm each fan returned to its recorded baseline.**
- FanHelper daemon: XPC Mach service, `FanHelperProtocol`, client signature check, independent re-clamping, 15 s watchdog → Auto, SIGTERM/sleep → Auto. Install via `scripts/install-helper.sh` (one-time `sudo`) — **not** `SMAppService.daemon`, which needs a signing identity this project doesn't have.
- Dropdown banner when the helper is missing or unreachable, showing the exact command to run.
- Wire the UI: mode picker, per-fan sliders bounded by each fan's real min/max, link-fans toggle, 2 s heartbeat. Quit → `setAllAuto`.
- **Accept**: Manual at 3000 RPM takes effect; `kill -9` the app → fans return to Auto within 20 s; quit → Auto immediately; sleep/wake → target restored; slider cannot exceed SMC min/max; uninstall script fully removes the daemon.

## Phase 4 — Presets, settings, persistence, launch at login ✅ DONE (2026-08-29)

**Accepted: 6/6 on `./scripts/verify-safety.sh`**, plus restore-on-launch verified directly. Only the reboot itself is outstanding.

| Check | Result |
|---|---|
| Helper installed from the app's Settings window | responding (done by the user; no shell script) |
| Preset resolves to the fan's own range | 55% → 5346 rpm of 5347 requested |
| Fans released on quit | mode back to 3 |
| Failsafe fires above the threshold | tripped, message shown |
| App forces itself back to automatic | `finalMode: auto` |
| Fans under macOS control after a trip | mode 3, 0 rpm |
| Restore on launch | launched with no arguments, fans 0 → 5323 rpm in 8 s |

**A real safety bug surfaced here.** The failsafe tripped correctly and the fans dropped to zero — then climbed back to full speed fifteen seconds later while it was *still tripped*, ending in manual mode. The deferred startup restore waits for the helper to become ready, and when it finally ran it called `setMode(.manual)` with nothing consulting the failsafe. Both `setMode` and `apply(preset:)` now refuse while tripped, and the failsafe is evaluated **last** in each poll so nothing in the same tick can re-enable manual behind it. A preset chosen while too hot is remembered but not acted on until the machine cools.

**The test that found it was wrong first**, which is worth remembering: it tripped at two degrees *above* idle, but manual control spins the fans up and cools the machine, so the threshold could never be reached — and the failsafe got blamed for the fans doing their job. Thresholds for a cooling mechanism have to be set below the resting value, and the assertion has to be on the mechanism firing rather than on a side effect.

**`SMAppService.mainApp` does not work here.** It reports `.notFound` however the app is launched and wherever it lives — checked from `~/Applications` and through LaunchServices, not just a build directory. Same root cause as `SMAppService.daemon`: no code-signing identity. Launch at login is therefore a user LaunchAgent, needing no privileges. `LoginItemManager.isUsingModernAPI` switches back automatically if a Developer ID is ever obtained.

**Still outstanding**: reboot with start-at-login enabled and a preset active, and confirm the menu bar returns with that preset already applied. Everything up to launchd starting the app is verified.

### Original checklist
- **Percentage-based** presets (SPEC.md "Presets are percentages") — Quiet 0 %, Cool 35 %, Max 100 %, resolved per fan, with resolved RPM shown. User CRUD, persisted in `UserDefaults`.
- Failsafe: ≥ 95 °C → force Auto + `⚠︎`; < 85 °C → restore previous mode; lost sensor readings in Manual → force Auto. Test by temporarily lowering the trip constant just above idle, verifying trip and recovery, then restoring it.
- Launch at login via `SMAppService.mainApp`; restore last mode on launch.
- **Accept**: reboot → app starts and reapplies the last preset unattended; failsafe trip and recovery both verified; settings survive relaunch; a preset gives sensible RPM at both ends of a fan's range.

## Phase 5 — Open-source release ✅ DONE (2026-08-29)

Version **0.1.0**. `dist/MacFanSpeed-0.1.0.zip` (720 KB) is ready to publish.

- **App icon** generated by `scripts/make-icon.swift` rather than checked in as a binary, so it is reviewable in a diff and regenerable at any size. Three swept blades, not four symmetric ones — an even count with mirrored curves renders as a flower, and three thicker blades stay legible at 16 pt.
- **`scripts/release.sh`** — clean build, tests, then verifies the archive before handing it over: every embedded file present, links only system frameworks, deployment target 14.0, arm64, signature valid. A release missing the embedded helper looks fine until someone tries to enable fan control on a machine that has never seen this repository.
- **README** rewritten for publication: real `github.com/bradr23/mac-fan-speed` URLs, both screenshots, and an honest note that fan control is verified on exactly one Mac model.
- `docs/menubar.png` and `docs/dropdown.png`, the latter showing temperature falling as fan speed rises.

**Accepted**
- Fresh `git clone` builds with `./scripts/build.sh release` and the result passes its self-check.
- Every `fanctl` command quoted in the README runs verbatim from that clone.
- The release zip, extracted to a directory with no source tree, runs and reads sensors correctly.
- The embedded installer locates its payload beside itself, with no repository present.

**A bug the screenshots caught.** The dropdown showed a permanent red *"The SMC rejected a write to 'F0Md' (error 130)"* while the fans were doing exactly what was asked. The two-second heartbeat re-forced the fan mode on every send, and re-writing a mode a fan already holds is refused. The mode is now written only when the fan is not already under control, and a transient error clears once a later send succeeds rather than staying on screen for the rest of the session. Worth remembering that this was invisible to every automated check — it took looking at the app.

**Before publishing**: create the GitHub repository, push, and attach `dist/MacFanSpeed-0.1.0.zip` plus its `.sha256` to a `v0.1.0` release.

## Working notes

- Test on real hardware, and never leave fans forced: `sudo ./build/fanctl auto`,
  then confirm every fan is back at the automatic baseline it reported *before*
  the test. That value is 3 on Mac16,8, not 0.
- SMC writes need root. Check `sudo` before suspecting the SMC code.
- References (adapt, check licences): exelban/stats (MIT) for Apple Silicon fan
  control; narugit/smctemp for M-series sensors. smcFanControl is GPL — do not
  copy from it.
- Build with `scripts/build.sh`. There is no `.xcodeproj` and none should be added.
