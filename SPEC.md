# Mac Fan Speed — Design Specification

A free, open-source macOS menu bar app for monitoring temperature and fan speed and manually controlling fan RPM on Apple Silicon Macs.

**Motivating problem**: macOS keeps fans off until the chassis is already hot, which makes a laptop uncomfortable on your lap. Being able to hold a low fan floor keeps the machine cool and quiet.

## Scope

- **Hardware**: **Apple Silicon only** (M1 and later, any variant). Intel Macs use an entirely different temperature path and are explicitly out of scope — the README says so plainly.
- **Fan count is discovered at runtime**, never assumed. Machines have 0 (MacBook Air), 1, 2, or more fans. A fanless Mac must run the app happily in monitor-only mode.
- **OS**: macOS 14 Sonoma or later.
- **Distribution**: open source (MIT), ad-hoc signed `.app` in GitHub Releases. Not sandboxed, not App Store, not notarized.

### Portability rule
This app runs on hardware the developer cannot test. Anything derived from the developer's own machine — fan count, sensor names, RPM ranges — is a **bug**. Read it from the system or degrade gracefully. When the hardware is unrecognised, say so in the UI rather than showing wrong numbers.

## User-visible behavior

### Menu bar (always visible)
- Hottest CPU temperature and fan RPM, e.g. `52° 2.4k`, in monospaced digits so the width doesn't jitter.
- With multiple fans, the bar shows the **average** RPM; per-fan detail lives in the dropdown.
- Fanless Mac: temperature only.
- Sensors unreadable: `--° ----`.

### Dropdown (on click)
1. **Temperature**: hottest CPU sensor (name + value).
2. **Fans**: one row per discovered fan — current RPM, and in manual mode a slider bounded by that fan's own SMC min/max. A "link fans" toggle (default ON) drives all fans from one slider. Hidden entirely when no fans exist.
3. **Mode picker**: `Auto` | `Manual` | preset names.
4. **Presets**: see "Presets are percentages" below.
5. **History chart**: last 10 minutes of temperature and fan RPM (Swift Charts).
6. **Settings**: launch at login, temperature unit (°C default, °F option), helper status.
7. **Quit** — always reverts fans to Auto before exiting.

### Presets are percentages, not RPM
A "2500 RPM" preset is meaningless on hardware whose fans top out at 3000 on one model and 7000 on another. Presets therefore store a **percentage of that fan's min–max range**, resolved per fan at apply time:

```
rpm = fanMin + (fanMax - fanMin) * percent
```

Built-ins: **Quiet** 0 % (fan minimum), **Cool** 35 %, **Max** 100 %. The UI shows the resolved RPM next to the percentage. Users can edit these and add their own.

### Modes
- **Auto**: SMC controls the fans (stock behavior). The app only reads.
- **Manual**: user sets a target RPM per fan, clamped to `[fanMin, fanMax]` as reported by the SMC.
- **Preset**: a named percentage set; internally identical to Manual once resolved.

### Temperature failsafe (mandatory, lowerable but never raisable)
- Hottest CPU sensor ≥ **95 °C** → immediately revert to Auto and show a warning state in the menu bar (`⚠︎ 96°`).
- Stay in Auto until temp < **85 °C** (hysteresis), then restore the user's previous mode.
- Constants in code: `Failsafe.assumedCriticalCelsius = 100`, `maximumTripCelsius = 95`
  (the ceiling *and* the default), `minimumTripCelsius = 60`, reset derived as
  trip − 10.
- **The critical temperature is an assumption, not a reading.** All 3222 SMC keys
  on a Mac16,8 were enumerated and none is a thermal limit. The most convincing
  candidate, `mlTJ`/`mlTj` reading 100.00 — `Tj` being the standard notation for
  junction temperature — is element ten of a twelve-entry percentage table
  (`mlT0…mlT3`, `mlTI…mlTL`, `mlTi…mlTl`, all 100.00). In a four-character key
  namespace there will always be letters that spell something thermal, so the
  constant is named `assumedCriticalCelsius` and never inferred from the SMC.
- Supplementary trips, none configurable: readings lost, readings stale (>6 s),
  battery >55 °C, storage >80 °C, CPU above 85 °C for 5 minutes, and
  `ProcessInfo.thermalState` at `.serious`/`.critical`. The last is
  supplementary only — `NSProcessInfo` documents that an unknown or unsupported
  thermal state reads `.nominal`, so it can never be evidence of safety.
- Also trips if temperature reads become unavailable while in Manual — no sensor means no safe manual control.

### Settings window
A real window, opened from **Settings…** in the dropdown, with four tabs:

- **General** — start at login, temperature unit, link fans.
- **Presets** — rename, re-percentage, add and delete. Each row shows the percentage *and* what it resolves to in RPM on the machine it is running on, so the abstraction is never opaque.
- **Fan Control** — helper status with **Install / Remove** buttons, and an explanation of why an administrator password is needed once.
- **About** — version, safety summary, bundle path.

SwiftUI's `Settings` scene is not used: in an `LSUIElement` app there is no menu bar to host Cmd-, and opening it programmatically depends on a private selector. `SettingsWindowController` owns an ordinary window instead, switching the activation policy to `.regular` while it is open so it can take focus, and back to `.accessory` on close.

### Sensors window
Opened from **Sensors…** in the dropdown, not from Settings: readings are what the app is *for*, not something you configure, and this is a window someone leaves open while watching the machine work. It lists every temperature sensor the machine exposes, grouped by what it measures, updating live.

**Naming: rename, never invent.** A sensor is renamed only where the hardware's own name says what it measures — `pACC MTR Temp Sensor0` genuinely identifies a performance core cluster, so "Performance cores 0" is a translation. `PMU tdie1` says only that it is a die sensor: this Mac reports **14 of them against 12 CPU cores**, so "CPU core 1" would be a guess presented as fact. Those become "Processor die 1", which is the whole of what is known. Unrecognised names are shown verbatim.

Each row keeps the hardware's own name and its **SMC key** beneath the readable one. The key comes from the HID service's `LocationID`, which holds the key as a four-character code — `NAND CH0 temp` is `TN0n`, `PMU tdie1` is `TP1b`. That is real identifying data, and it makes a reading traceable and quotable in a bug report from hardware nobody has catalogued.

Readings repeated by several services collapse to one row with the hottest value and a `×N` count; on a Mac16,8 that turns 52 raw readings into 22 rows.

Categorisation is **display only**, deliberately separate from `SensorTier`, which decides what the failsafe acts on. Grouping a sensor under the wrong heading is cosmetic; misclassifying one as CPU is a safety matter, so a nicer label can never change what the failsafe watches.

### Persistence & startup
- Settings persist in `UserDefaults`. **Speeds are stored as percentages, never RPM**, so preferences carried to another Mac still mean what they said.
- The last mode — auto, manual, or a specific preset — is restored on launch once the fans and helper are both known, so a reboot lands back where the user left it with nothing to click.
- **Launch at login is a user LaunchAgent** at `~/Library/LaunchAgents/io.github.bradr23.MacFanSpeed.plist`, written by the app. No privileges are needed — that directory belongs to the user.

  `SMAppService.mainApp` would be the modern route, but it reports `.notFound` for this app however it is launched and wherever it lives (verified from `~/Applications` and through LaunchServices, not just from a build directory). The cause is the same one that rules out `SMAppService.daemon`: registration needs a real code-signing identity. `LoginItemManager.isUsingModernAPI` detects when that changes, and prefers `SMAppService` automatically if a Developer ID is ever obtained.

  A login item records the app's *current path*, so the Settings window warns when the app is running from outside an Applications folder, and a plist pointing at a moved app is reported as disabled rather than as working.

### Installing on another Mac
Everything needed to enable fan control ships **inside the bundle** — `MacFanSpeedHelper`, its launchd plist, `fanctl`, and both install scripts live in `Contents/Resources`. A machine with only the downloaded app can enable fan control from the Settings window; nothing depends on the source tree.

`HelperInstaller` runs the embedded script through AppleScript's `with administrator privileges`, which shows the standard authentication dialog. A cancelled prompt is reported as cancelled, not as an error. The same scripts work unchanged from the repo (`sudo ./scripts/install-helper.sh`) — they locate their payload beside themselves first and fall back to `build/`.

## Architecture

Two processes. Only the tiny root helper can write to the SMC.

```
┌────────────────────────────────┐      XPC (Mach service)      ┌──────────────────────────────┐
│ MacFanSpeed.app (user)         │ ───────────────────────────▶ │ FanHelper (root LaunchDaemon)│
│  - SwiftUI MenuBarExtra UI     │  setFan(i, rpm) / setAuto    │  - SMC WRITES only           │
│  - SMC reads (RPM, min/max)    │ ◀─────────────────────────── │  - re-clamps every request   │
│  - HID temperature reads       │        ack / error           │  - 15 s watchdog → Auto      │
│  - control loop + failsafe     │                              │  - SIGTERM/sleep → Auto      │
└────────────────────────────────┘                              └──────────────────────────────┘
```

### App (`MacFanSpeed.app`)
- SwiftUI `MenuBarExtra`, `LSUIElement = YES` (no Dock icon).
- **Poll loop** every 2 s: read temps and fan RPMs, append to a 300-sample ring buffer (10 min), update UI, evaluate the failsafe, and in Manual/Preset mode re-send the current targets as a heartbeat.
- All SMC **reads** happen in-process and need no privileges.

### FanHelper daemon
Installed as a classic LaunchDaemon. `SMAppService.daemon` is not used: it requires a real code-signing identity, and this project ships ad-hoc signed.

- Binary at `/usr/local/libexec/MacFanSpeedHelper` (root:wheel, 755).
- Plist at `/Library/LaunchDaemons/io.github.bradr23.MacFanSpeed.helper.plist` (root:wheel, 644), declaring `MachServices` = `io.github.bradr23.MacFanSpeed.helper`.
- Installed by `scripts/install-helper.sh` (one-time `sudo`), removed by `scripts/uninstall-helper.sh`.
- XPC protocol:
  ```swift
  @objc protocol FanHelperProtocol {
      func setFan(index: Int, targetRPM: Double, reply: @escaping (String?) -> Void) // nil = ok
      func setAllAuto(reply: @escaping (String?) -> Void)
      func version(reply: @escaping (String) -> Void)
  }
  ```
- **Validates independently**: fan index within `FNum`, RPM re-clamped against limits the helper reads itself. Never trusts the client's numbers.
- **Watchdog**: each `setFan` resets a 15 s timer; if it fires, all fans revert to Auto. The app's 2 s heartbeat keeps manual mode alive, so a crashed or killed app cannot leave fans pinned.
- Also reverts to Auto on XPC invalidation, `SIGTERM`, and system will-sleep (the app re-applies on wake).
- **Sleep must be observed through `IORegisterForSystemPower`, not `NSWorkspace.willSleepNotification`.** `NSWorkspace` notifications are delivered per *user session*; a LaunchDaemon runs in the system domain with no session, so the observer registers without error and is then never called. This was shipped that way in 0.1.0 and went unnoticed precisely because it fails silently — the daemon logged a restore for every other exit path over weeks of use and not one for sleep. Answering `kIOMessageSystemWillSleep` also holds sleep off until the fans are actually released, which the notification could not do even if it had fired. The daemon links IOKit and **not** AppKit; keep it that way.
- **Client verification**: on each connection, identify the peer with `SecCodeCopyGuestWithAttributes` and check it against a `SecRequirement` of `identifier "io.github.bradr23.MacFanSpeed" or identifier "fanctl"`. Two limitations, both consequences of shipping without a Developer ID, and both stated rather than skipped:
  1. No team-ID check is possible, so the requirement matches on signing identifier. That stops a different or tampered binary, but not a re-signed impostor.
  2. The peer is identified by **PID**, because `NSXPCConnection.auditToken` — which would be race-free — is private API. A PID can in principle be recycled between the call and the check.

  The daemon's real safety property does not rest on this check: it exposes only fan targets, re-clamps them against limits it reads itself, and reverts to automatic on any silence. The worst a spoofed client achieves is a fan speed the hardware already permits.

### SMC layer (SMCKit, shared)
Talks to the `AppleSMC` IOKit service via `IOConnectCallStructMethod` (kernel index 2).

| Key | Type | Meaning |
|---|---|---|
| `FNum` | ui8 | number of fans |
| `F{i}Ac` | flt | fan actual RPM |
| `F{i}Mn` / `F{i}Mx` | flt | fan min / max RPM |
| `F{i}Tg` | flt | fan target RPM (**write**, root) |
| `F{i}Md` | ui8 | fan mode (**write**, root) — see below |

The kernel's `SMCParamStruct` is **80 bytes**. Swift does not reproduce C's trailing
padding for nested structs automatically, so `SMCKeyInfoData` carries three explicit
reserved bytes; without them Swift lays the struct out as 76 bytes and every request
is silently misaligned. `SMCConnection` verifies the size and key field offsets at
construction and refuses to talk to the SMC on mismatch.

#### Taking manual control (verified on Mac16,8, macOS 26.3.1)

From the M3 generation onward, `thermalmonitord` holds the fans and the firmware
refuses `F{i}Md` writes with **error 0x82 (130)** — including a write of the key's
own current value, which is how that was proven to be a lock rather than a bad
value. The working sequence is:

1. Write **`Ftst = 1`**. The firmware begins yielding; the mode drops 3 → 0 and
   the fans come off zero to their minimum.
2. **Retry `F{i}Md = 1` until it is accepted.** The yield happens somewhere in a
   window, not at a fixed moment — on a Mac16,8 fan 0 landed at **5.3 s** and
   fan 1 immediately after. A single attempt following a fixed sleep misses it;
   this is the difference between the sequence working and appearing impossible.
3. Write **`F{i}Tg`**. The fan then tracks the target (5347 requested → 5320–5399
   observed).
4. **`Ftst` must stay 1 for as long as manual control is held.**

Releasing reverses it: restore each `F{i}Md` to its recorded baseline **while
still unlocked** (the mode is not writable otherwise), then write `Ftst = 0`.
Order matters, and clearing `Ftst` first strands the fans.

#### Fan mode semantics are not 0/1

Intel-era documentation describes `F{i}Md` as 0 = automatic, 1 = forced. **This does
not hold on Apple Silicon.** An idle Mac16,8 (M4 Pro) reports `F0Md = F1Md = 3` with
nothing having ever written to the SMC, alongside `F{i}Ac = 0` (fans genuinely stopped)
and min/max of 2317/7826 RPM.

Consequently:
- Never test a fan for "automatic" by comparing its mode against 0.
- `Fan.modeRaw` carries the value verbatim; no automatic/forced judgement is made from it.
- On unfamiliar hardware, establish the forced value **empirically** with
  `sudo fanctl probe-mode` — it performs one controlled write, reports what the mode
  reads back as, and restores the original state — rather than assuming either value.

- Manual control of fan *i*: write `F{i}Md`, then `F{i}Tg = rpm`. Release by restoring
  the machine's automatic baseline value, which is what the mode read *before* any write.
- **Guardrail**: the write API accepts only a fan index and an RPM — it is structurally incapable of writing any other key. Every write clamps to that fan's reported min/max.
- Reference: MIT-licensed [exelban/stats](https://github.com/exelban/stats) for the Apple Silicon fan write path. **Do not copy from smcFanControl (GPL).**

### Temperature layer (app + CLI)
Apple Silicon CPU temperatures are not in classic SMC keys. Read them through `IOHIDEventSystemClient`: create a client, match services with `PrimaryUsagePage: 0xff00, PrimaryUsage: 5` (AppleSensor temperature), read `kIOHIDEventTypeTemperature`.

**Sensor names differ across chip generations and variants, so they must not be hardcoded to one machine.** Classify discovered sensors into tiers, most specific first:

1. **`coreCluster`** — names containing `ACC MTR Temp`, the per-core clusters (`pACC` performance, `eACC` efficiency).
2. **`socDie`** — names containing `SOC MTR Temp`, `PMU tdev` or `PMU tdie`.
3. **`unclassified`** — anything not recognised and not excluded.
4. **`excluded`** — known non-CPU sensors: `batt`, `NAND`, `charger`, `ambient`, `gas gauge`, `PMU tcal`, `display`, `airport`, `wifi`, `camera`, `speaker`.

"Hottest CPU" is the max within the most specific tier that produced any reading. **Tier order encodes confidence, not temperature** — a cooler core-cluster sensor beats a hotter die sensor. If only excluded sensors exist, report temperature as unavailable rather than guessing; the failsafe treats that as a reason to force Auto.

Keep the patterns as a single table in code so new hardware is a one-line change. `fanctl temps --dump` prints every sensor with its classification, which is what users on unknown hardware should attach to a bug report.

#### Hardware variation this must survive

Researched rather than assumed, because the developer has exactly one Mac. What is
**documented**, and what remains **unknown**, are separated deliberately — an
unknown treated as a fact is how single-machine software breaks on other people's
hardware.

| Aspect | What varies |
|---|---|
| Fan count | 0 (MacBook Air) to 2 (MacBook Pro, Mac Studio); Mac Pro has 3 physical fans though its `FNum` is unverified. The 24" iMac ships with **1 or 2 fans in the same model family**, so fan count can never be derived from the model identifier. |
| Sensor names | Two schemes. M1 and M1 Pro expose a named family (`pACC MTR Temp Sensor2`, `SOC MTR…`, `PMGR SOC Die…`, `ANE MTR…`, `ISP MTR…`); M2 onward expose only generic `PMU tdie`/`tdev` sensors. Indices start at 0 on some machines and 1 on others. |
| `PMU2` | A **second power controller on single-die machines** (base M1, base M4, A18) — *not* a second die. M2 Ultra and M3 Ultra dumps contain no PMU2 sensors at all. |
| Opaque names | `PMU TP0s`, `PMU TP1g`, `PMU2 TR1d` and similar appear on M1 Pro through M2 Ultra. The first letter appears to be the quantity (T temperature, V voltage, I current) and the rest an opaque rail identifier; what each measures is not published. |
| Sensors that are not measurements | `PMU tcal` is a **static calibration constant** — 51.85 on every Apple Silicon machine regardless of load. `PMU tdev*` reads **garbage**: ≈ −21.7 on M1, ≈ −9201 on M4 Pro. Neither may feed the failsafe. |
| GPU sensors | Present on M1 (`GPU MTR Temp Sensor1`, `…4`) and **absent from M2 onward** — no HID GPU sensor exists on M3, M4 or M5. |
| Sensor indices | Not contiguous and not zero-based. M1 reports `pACC MTR Temp Sensor` at indices 2, 3, 4, 5, 7, 8, 9 — no 0, no 1, no 6. `PMU tdie` starts at 0 on M1 Pro and M2, at 1 elsewhere. |
| Renaming across OS versions | The same M1 reports `PMU2 TR1d` on macOS 11–13 and `PMU2 tdie1` on macOS 15+, with every other sensor in the dump byte-identical. Naming is **macOS-version dependent, not chip dependent** — so matching is on the `PMU2 ` prefix, never on the `TR*` spelling. |
| Battery sensors | Absent entirely on every Mac mini and Mac Studio, with nothing replacing them. Present and duplicated 4–6× on laptops. |
| Firmware unlock | Not needed on M1. Required on M3 and M4, laptops and desktops alike. Reportedly absent again on M5, where the mode key is also said to be spelled lowercase `F{i}md`. |
| Min/max limits | **Advisory, not enforced.** The SMC has been observed accepting targets below the reported minimum, stopping fans completely. |

Consequences, all implemented:
- `Ftst` absence means "no unlock needed", never failure — determined by probing, not by chip.
- Both `F{i}Md` and `F{i}md` are probed; the documented spelling is tried first.
- Sensor classification matches both naming schemes, and `tcal` is excluded on the bare word so `PMU2 tcal` is caught too.
- Fan discovery scans until it has found `FNum` fans rather than assuming indices `0..<FNum`.
- **The app's own clamping is the real protection.** Since limits are advisory, a fan reporting an implausible range is refused outright rather than driven to a clamped value.
- **`tcal` and `tdev` are excluded from the failsafe input by name**, not by relying on the plausible-range filter. `tdev`'s −21.7 on M1 sits barely outside that range, so hardware reporting a merely odd value rather than an absurd one would otherwise slip through. Both are still shown in the Sensors view — they are real readings, just not CPU temperature.
- `Ftst` is re-verified against the hardware rather than trusted from a cached flag, because the firmware clears it across sleep.

Sensor inventories are now confirmed from real dumps for M1, M1 Pro, M1 Max, M2, M2 Pro, M2 Max, M2 Ultra, M3 Pro, M3 Max, M3 Ultra, base M4, M4 Pro, M4 Max and M5. Each is covered by a test asserting the whole inventory behaves — every sensor categorised, none lost, and the failsafe picking a real die sensor rather than the calibration constant or the garbage `tdev` family.

Still unknown, and deliberately handled defensively rather than guessed: whether M2 needs the unlock, what `FNum` reads on a Mac Pro, and whether the lowercase mode key is real. No public HID sensor dump could be found for **M1 Ultra, the Mac Pro, or any iMac** — those rely entirely on the fallback behaviour above, which shows unrecognised sensors verbatim rather than mislabelling them.

Sensor names are **not unique identifiers**: they repeat between two and eight times per machine across services, and several sensors can share one name while being physically distinct — this Mac reports six different battery sensors all called `gas gauge battery`. Grouping is therefore keyed on the SMC key from the HID service's `LocationID`, never on the name.

#### Observed hardware (verified 2026-08-29)

| Machine | OS | Sensors | CPU sensors found |
|---|---|---|---|
| Mac16,8 (M4 Pro) | macOS 26.3.1 | 52 | `PMU tdie1`–`tdie14`, tier `socDie` |

**Tier 1 was empty on M4 Pro** — that machine exposes no `ACC MTR Temp` sensors at all, contrary to what the M1-era documentation suggests. The tiered fallback is therefore load-bearing, not a nicety: hardcoding tier-1 names would have produced no reading on the machine this was written on.

Two exclusions matter more than they look:
- `PMU tcal` reads roughly **15 °C above** the die sensors at idle (51.8 °C versus ~35 °C). Treating it as a CPU sensor would inflate every reading and could trip the 95 °C failsafe early.
- Macs report the same sensor name from **several services** with slightly different values (each `PMU tdieN` appeared three times). Deduplicate by name, taking the hottest, before display.

Reference: [narugit/smctemp](https://github.com/narugit/smctemp) for M-series sensor handling. Check licence headers before reusing.

## Project structure & build

**Swift Package Manager.** Xcode is installed on the dev machine, but SPM is kept deliberately: contributors can build with Command Line Tools alone, there is no generated `.xcodeproj` to drift, and the release path needs no Xcode-specific machinery.

Targets:
1. `MacFanSpeed` — app executable, assembled into a bundle by `scripts/build.sh`.
2. `FanHelper` — executable installed as the root daemon.
3. `SMCKit` — library shared by all executables.
4. `fanctl` — debug CLI. Permanent: the fastest way to exercise the low-level layer, and the diagnostic users run on unknown hardware.

SPM emits bare executables, so `scripts/build.sh` assembles the bundle: binary into `Contents/MacOS/`, `Resources/Info.plist` (carrying `LSUIElement`) into `Contents/`, icon into `Contents/Resources/`, then ad-hoc signs.

```
scripts/build.sh [debug|release]   # build + assemble build/MacFanSpeed.app
scripts/run.sh                     # build, kill running copy, launch
scripts/install-helper.sh          # sudo: install the root daemon
scripts/uninstall-helper.sh        # sudo: remove it
scripts/release.sh                 # versioned zip for GitHub Releases
```

### Code signing and Gatekeeper
There is no Developer ID, so releases are **ad-hoc signed**. A downloaded build is quarantined and macOS will refuse the first launch. The README documents both remedies: right-click → Open, or `xattr -dr com.apple.quarantine /Applications/MacFanSpeed.app`. Building from source locally produces no quarantine flag and just works. If a Developer ID is obtained later, only `build.sh` and `release.sh` change — nothing in the app's architecture depends on being unsigned.

### Development affordances

Two environment variables exist because the menu bar is awkward to inspect automatically.

`MFS_SELFTEST=1` runs a headless check and exits. It reports the status item, the activation policy, whether real sensor readings arrived, whether the poll loop advanced, and the values behind the menu bar label — so its output can be compared directly against `fanctl`. Ends with `selftest.result: PASS` or `FAIL`.

```
selftest.detail: temp=38.8°C (PMU tdie6) fans=[0, 0] samples=3 label='39° 0'
```

`MFS_PREVIEW=1` opens the dropdown's contents in an ordinary floating window. A `MenuBarExtra` panel only appears when its status item is clicked, and automating that click needs Accessibility permission; the preview window can be screenshotted without it.

## Safety rules (binding)

1. Never write SMC keys other than `F{i}Md`, `F{i}Tg` and `Ftst`; always clamp to SMC-reported min/max. `Ftst` is the firmware unlock (see "Taking manual control") and is the third and last member of that closed set.
2. Every exit path — quit, crash via watchdog, sleep, helper termination — ends with fans in Auto **and `Ftst` back to 0**. Leaving `Ftst` set keeps thermal management handed to a process that may no longer exist; it is the worst state this code can produce, so the clearing write is verified and retried rather than issued once.
3. The temperature failsafe is mandatory and never user-*raisable*; the ceiling equals the shipped default.
4. Losing temperature readings while in Manual forces Auto.
5. Never assume fan count, RPM range, or sensor names. Read them, or degrade visibly.
6. After any test session that forced fan mode, run `sudo fanctl auto` and verify every fan
   returned to the **automatic baseline that machine reported before the test** (3 on Mac16,8),
   not to 0. Record the baseline with `fanctl fans` before writing anything.

## Out of scope

Intel Macs, notifications, per-app rules, localization, auto-update, App Store distribution.

Per-fan curves are a deliberate non-goal: a curve is one machine-wide intent, the same way a preset already is. Unlinked per-fan speeds remain available on fixed-speed profiles.
