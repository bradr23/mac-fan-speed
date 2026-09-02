# Changelog

Notable changes in each release. Versions follow [semantic versioning](https://semver.org).

## 0.5.0

Full audit of 0.4.1 — eight lenses over the whole codebase, every significant
finding put through an adversarial pass that defaulted to refuting it. Four high
and thirteen medium findings, all fixed here.

The fixes were then reviewed the same way, which found fourteen defects *in the
fixes* — four of them more serious than the finding being fixed. Those are fixed
too, and the ones that changed the shape of a fix are described below.

Running `scripts/verify-safety.sh` afterwards then reported a failure that turned
out to be the script's own doing, and auditing the script found sixteen more ways
it could report a result that was not about the product. That audit is the last
section here, because an acceptance gate that can lie in either direction is
worse than no gate.

### Fixed

- **Three routes could leave the fans forced while the daemon believed it owned
  nothing.** Every restore path — the watchdog, client disconnect, sleep,
  `SIGTERM`, the daemon's own failsafe — is gated on one flag, so any route that
  leaves the hardware forced while that flag reads false disarms all of them at
  once, silently.

  `setAllAuto` cancelled the watchdog, stopped the thermal watch and cleared the
  flag *before* checking whether the restore had worked; it now delegates to the
  one implementation that gets that right. A throw partway through `setTarget`
  returned an error and armed nothing, leaving thermal management yielded and
  possibly a fan pinned; ownership now begins at the first hardware write rather
  than at success, published by the writer as `mayHoldFans`. And because that
  flag is per-process while the hardware is not, `setAllAuto` now attempts a real
  restore even when this daemon has no record of forcing anything — which is
  exactly the state a replaced, kickstarted or crashed daemon starts in, and
  where every client-facing release used to return success for doing nothing.

- **Restore was a silent no-op on Macs that need no firmware unlock.**
  `captureBaseline` decided a mode reading was untrustworthy only when `Ftst` was
  non-zero. On hardware that does not need the unlock — SPEC records M1, and M5
  reportedly — that key is absent or zero *even while the fans are forced*, so a
  fresh process meeting already-forced fans recorded "forced" as the automatic
  baseline and every later restore wrote it back. It worked on the developer's
  M4 Pro purely because that machine has `Ftst`.

  The baseline is now written to `/var/db` before the first hardware write, so a
  process that restarts while fans are forced still knows what "automatic" was,
  and `setTarget` refuses outright without one. Persistence has its own hazards,
  and the review found all of them: the store refuses to record the forced value
  (persisting one turns a transient mis-read into a permanent, unclearable one),
  it carries a `kern.boottime` stamp so a file from an earlier boot cannot
  outrank the live modes, it merges with observation instead of short-circuiting
  it — a partial file used to leave a second fan permanently uncontrollable —
  and it rewrites only on change instead of once per fan per two-second
  heartbeat.

- **One failed `Ftst` read was cached as "this Mac has no unlock key".**
  `(try? read) != nil` cannot distinguish a missing key from a read that failed,
  and the answer was cached permanently: one transient failure made `relock`
  return "confirmed clear" without ever writing the key. Only
  `SMCError.keyNotFound` is now evidence of absence, and an undetermined answer
  is reported as an error rather than as success.

- **A single transient sensor read failure handed the fans back.** The HID
  reader returns empty if its service copy fails once, which happens on any Mac.
  Both the app's failsafe and the daemon's watch now tolerate two misses and act
  on the third. On a warm machine this matters more than it sounds: the release
  needs a reading below the reset point, so a momentary glitch could hold the app
  in Auto far longer than the glitch. The miss counter belongs to one manual
  session and is cleared on leaving it.

- **The daemon's thermal watch could stop and never restart.** It was gated on
  `TemperatureReader.isAvailable`, which only reports that a HID client object
  exists, while the trip used an actual reading — the two tested different
  things. The watch is now gated on sensing having been proven, a slow recovery
  tick re-arms it as soon as readings return rather than waiting for a client to
  ask for something, and the 95 °C ceiling refuses a request on the strength of
  the reading alone: a reading is evidence of itself, and requiring sensing to be
  "proven" first opened a window in which a genuinely hot machine's fans were
  taken over for the whole twelve-second unlock retry.

- **A queued fan request could re-force the fans immediately after the sleep
  restore.** The app re-sends its target every two seconds and does not know
  sleep is happening. The daemon now refuses requests from the moment it starts
  the sleep restore until it wakes — with a timeout, because a gate that only a
  wake message can lift is a gate that refuses everything forever if that message
  never arrives, which is this project's most repeated bug shape.

- **An unreadable `F{i}Md` fabricated an automatic baseline of 0.** `?? 0` made a
  failed read indistinguishable from a genuine zero, and that value was cached
  and written back on every restore — setting a mode the machine never had. Fans
  now report whether their mode was actually read, and only reported modes become
  a baseline.

- **The dwell timer accumulated while macOS owned the fans**, so a machine that
  had been warm on its own handed a freshly-enabled manual mode a timer that was
  already expired, and it tripped on its first tick — blaming the user's setting
  for heat that predated it.

- **The dropdown kept showing a live curve readout after the app had dropped to
  Auto**, and editing the active preset in Settings never reached the fans. Both
  are fixed; the edit hook takes the edited preset's id, because wiring it to
  every row while resolving the *active* preset meant tuning one profile
  overwrote the running profile's speed and reset its filter, hysteresis and slew
  state on every drag tick.

- **The slider and preset buttons were live but inert on a Mac whose fans report
  no limits.** The daemon refuses every target there, so the controls moved and
  the fans did not. That state now explains itself instead — and keeps a route
  back to Auto, since the Auto button was the only `setMode(.auto)` in the app;
  manual control is refused up front rather than entered and then discovered to
  be useless. One transient limits read no longer swaps the whole section for a
  permanent-sounding warning.

- **`scripts/verify-safety.sh` could report the failure it exists to catch as a
  pass.** It hardcoded fan mode 3 as "automatic", which fails on any Mac that
  rests at a different value, and it recorded the resting mode without first
  making sure the fans were at rest — read while a copy of the app was still
  holding Manual, both release checks compared forced against forced and printed
  PASS. It now hands the fans back, waits, records what the machine actually
  rests at, and refuses to run if it cannot read it. Its cleanup also checks that
  the rebuild it performs succeeded, so a below-idle test ceiling cannot survive
  in the installable payload.

- **SPEC corrections.** It classified the garbage `PMU tdev` family as a CPU tier
  the failsafe reads, when the code excludes it by name before classification
  runs; it documented a menu bar warning state on failsafe trip that does not
  exist; and a daemon doc comment stated the opposite of the code directly
  beneath it.

- **The daemon could write down a mode of 0 as "automatic".** Startup clears
  `Ftst` when it finds it set and then captured the baseline after a fixed
  three-second sleep — shorter than the reclaim this hardware measurably takes
  (2.4–3.5 s in the developer's own logs, and the code's own `reclaimWaitSeconds`
  documents ten). A capture landing inside that window reads the value the mode
  passes *through* on its way back, which SPEC records as 0, and writes it down
  as the resting state. Every later restore then writes `F{i}Md = 0` — the exact
  write hard rule 3 forbids. The daemon's own comment records a previous run
  doing this; the mitigation chosen then was the guessed sleep.

  It now waits for the firmware to actually take the fans back rather than
  guessing an interval, which is what hard rule 1a asks for, and says so in the
  log when it does not. `BaselineStore` refuses to record 0 alongside the forced
  value, and `fanctl probe-mode` had the same guessed three seconds.

- **`waitForFirmwareToReclaim` accepted the mid-handshake value as a completed
  handover**, so a poll landing on a transient 0 reported the fans as back —
  which is what deletes the crash-recovery file and disarms ownership. It also
  could never be satisfied on a Mac whose resting mode *is* the forced value, so
  every restore there burned ten seconds and reported failure. It now waits for
  each fan to reach its own captured baseline, and short-circuits the case it
  cannot decide.

- **The daemon started without saying it could not clear `Ftst`.** `relock`
  documents its return as "never silently swallows the failure", and its most
  important caller discarded it. A failed clear leaves the firmware yielded,
  which makes every later capture refuse and every request throw
  `noBaselineRecorded`, with nothing in the log to explain why.

- **Quitting after a failsafe trip skipped the app's own blocking release.**
  `releaseFansForShutdown` asked "is the UI in manual", when the question that
  matters is "have I taken control and not yet had a release confirmed". Those
  differ exactly when it counts: after a trip — or an ordinary click on Auto —
  the mode is already Auto while the release that accompanied it is still in
  flight, so hard rule 2 was left entirely to the daemon's disconnect backstop,
  which starts after the process has exited. The app now tracks the debt and
  blocks on it.

- **The app could re-command manual on top of a release the daemon was still
  executing.** Everything in the daemon is serialized on one queue and a restore
  waits for the firmware, so a take-control request sent two seconds later queued
  behind it and then paid the whole unlock retry. A release is now tracked while
  in flight and manual control refuses to re-enter until it lands.

- **A dead floor in the failsafe's reset point.** `resetCelsius` was
  `max(trip - hysteresis, 40)`. The floor was unreachable in every real
  configuration — the trip clamps to 60...95, so the reset is never below 50 —
  and actively wrong in one artificial one, where it produced a reset *above* the
  trip and made every tick trip and the next release. Removing it can only lower
  the reset, which is the conservative direction.

### Changed

- **The daemon's decision-making moved into value types that can actually be
  tested.** The executable target is in no test bundle, so logic left inside it
  was untestable — and the regression tests written for the 0.4.0 lockout
  asserted against a *transcription* of that logic into the test file, which
  would have stayed green through any regression in the real thing. That is worse
  than no test, because it reads as coverage.

  `ThermalWatchState` (the whole thermal state machine), `StalenessJudge` (the
  sleep-versus-wedge decision from 0.4.1, which had no test at all) and
  `BaselineStore` (the persistence rules that decide whether forced fans can ever
  be handed back) are now plain types in `SMCKit` and the app, with 41 tests
  between them. The transcription-based suite was deleted rather than kept
  beside them. Every new test was mutation-checked: reverting the behaviour it
  describes makes it fail.

- **`scripts/verify-safety.sh` is substantially rewritten.** It is the gate for
  hard rule 2, and it could report results that were not about the product in
  both directions.

  It manufactured its own failure: to make the failsafe fire without heating the
  machine it patched the assumed critical point below idle, which moved the
  ceiling but not the floor, so the reset point landed *above* the trip. Every
  tick tripped and the next released, the app flapped once per poll, and it
  happened to be mid-cycle when the harness quit — at which point the old
  mode-based shutdown guard skipped the blocking release, the daemon's disconnect
  restore took 3.5 s, and the script's fixed `sleep 3` read the fans half a
  second too early and called it a failure. Four separate defects in one line of
  output.

  It could also pass without testing anything. Every fan-state assertion read
  fan 0 only, so a second fan could stay forced through three PASSes. The
  expected RPM for a preset was computed, printed, and never asserted. The
  quit-release check passed whether or not the quit-release path had run. The
  patched build's exit status was ignored, so a failed build meant testing the
  *previous* binary — with the real 95 °C ceiling — and reporting "failsafe did
  not fire". And it never checked that the installed root daemon matched the tree
  it was testing, which is how a 0.5.0 app came to be tested against a 0.4.0
  daemon with the result attributed to code that was not running.

  Its own safety net was inert too: both "put the fans back whatever happens"
  calls used `fanctl auto`, which needs root, in a script whose header says to
  run it without sudo — silenced by a redirect and swallowed by `|| true`. They
  now go through the daemon, which is already root. The script refuses to run as
  root at all, because under sudo it leaves a tracked source file and the whole
  app bundle root-owned.

  Now: it refuses to run against a mismatched daemon, polls for a condition
  instead of sleeping a guess, checks every fan, asserts the resolved RPM, proves
  the binary under test carries the patched threshold, fails if the failsafe
  cycles more than once, prints what it actually saw when a check fails, and
  reports a fanless Mac — an explicitly supported configuration — as skipped
  rather than failed.

- **Two regression tests were vacuous.** `testResetIsAlwaysBelowTrip` and
  `testEverySettableCutoffIsAtOrBelowTheDaemonCeiling` walk a `stride` over a
  derived range. A positive stride whose upper bound is below its lower bound
  yields nothing, so both passed by executing zero times — in exactly the
  configuration that breaks the invariant they exist to protect. They now assert
  the range is non-empty and count what they checked.

## 0.4.1

### Fixed

- **The app stopped controlling fans after sleep and never resumed.** The
  stale-readings watchdog added in 0.3.0 compares the age of the last sensor
  snapshot against a threshold of six seconds. That is right for the failure it
  was written for — a poll queue that has wedged while the app carries on — but a
  process that was *suspended*, because the machine slept or App Nap froze its
  timer, resumes holding an equally old timestamp for an entirely innocent
  reason. The check could not tell the two apart, so every sleep looked like a
  stalled control loop.

  Worse, the trip bypassed `Failsafe` and set the mode directly, so the failsafe
  never knew it had happened and never issued the release that restores manual
  control. It was a one-way door: after waking, the app sat in Auto showing
  "Temperature readings stopped updating N s ago" until someone clicked a preset.

  A wedged queue is now distinguished from a suspension by whether `poll()`
  itself also stopped — a wedge leaves the poll timer running and is caught
  within a couple of ticks, while a suspension shows up as a gap in both. The
  trip is routed through `Failsafe` so it is recorded and can be released, and
  the app additionally resets its clocks on `NSWorkspace.didWakeNotification`,
  which — unlike in the daemon, where the equivalent notification never arrives —
  does reach an app with a user session.

## 0.4.0

Security audit of 0.3.0, and its fixes. No privilege escalation was found; the
issues were that the safety architecture sat on the wrong side of its own trust
boundary, and that the daemon's client check was weaker than documented.

### Fixed

- **The privileged daemon now runs its own failsafe.** Every thermal protection
  used to live in the app — the cutoff, the escalation floor, the battery,
  storage and dwell rules — while the daemon, which is the trust boundary and
  explicitly does not trust the app, never read a temperature at all. It clamped
  a requested speed to the fan's range and nothing else. Any process that could
  reach the Mach service could therefore pin the fans at minimum indefinitely,
  heartbeating to defeat the 15-second watchdog, with no temperature check
  anywhere in the privileged process. The daemon now reads its own temperatures
  on its own timer against a ceiling compiled into `ThermalLimits`, and refuses
  to force a fan while it is hot. Nothing about it depends on a client.
- **Fan ownership is per-connection.** The heartbeat checked only whether *any*
  fan was forced, so any accepted connection could keep another client's fans
  alive forever; and releasing only when the *last* client disconnected let an
  unrelated connection hold someone else's fans. Fans are now released when the
  client that forced them goes, and only that client's heartbeat feeds the
  watchdog. The 0.2.0 fix — a short-lived `fanctl` no longer stealing control
  from the app — is preserved.
- **Non-finite targets are rejected at the XPC boundary.** `min(max(rpm, lo), hi)`
  is NaN-transparent, because every comparison against NaN is false, so a NaN
  arriving over XPC survived the clamp, reached the SMC write, and then trapped
  the `Int(...)` that formatted the error — killing a root process. Error
  messages no longer use `Int()` on values that reached them for being invalid.
- **A fan whose limits the SMC never reported is no longer driven.** A missing
  `F{i}Mn` read as `?? 0`, which is indistinguishable from a fan that genuinely
  reports a floor of zero — and a zero floor is a clamp that permits stopping the
  fan outright, on hardware nobody has tested. Such a fan is now shown and
  monitored but never driven, and the dropdown says so instead of printing a
  fabricated range beside a slider that would only ever be refused.
- **Errors from a multi-fan machine are no longer lost.** Each fan's reply
  overwrote the last, so one fan's success erased another's failure.

### Documented honestly

- SPEC.md claimed the daemon's signing requirement "stops a different or tampered
  binary" and that "the worst a spoofed client achieves is a fan speed the
  hardware already permits". Both were wrong. An ad-hoc signature's identifier is
  chosen by whoever builds the binary, and the linker signs automatically using
  the *output filename* — `swiftc -o fanctl x.swift` satisfies the requirement
  with no signing step at all, while the byte-identical `notfanctl` is rejected.
  Authorization reduced to what the client file was called. And the exposure was
  never the speed; it was the unbounded duration, because the only thing that
  would have ended it lived in the untrusted client.

### Also fixed, found reviewing the above

The daemon fix introduced two defects of its own, both caught before release:

- The thermal watch was gated on "a HID client exists" but tripped on "a reading
  arrived". On a Mac where the first is true and the second never is, the daemon
  latched a lockout that nothing could lift — because the only thing that lifts
  it is the reading that never comes — killing fan control for the life of the
  daemon while blaming heat. A single transient failed read did the same on any
  Mac. Losing readings now degrades the daemon's failsafe instead of latching,
  and the watch only starts once a reading has actually been obtained.
- A *failed* restore cleared all daemon state and stopped the thermal watch, so
  the one case where the fans might still be forced was the case where
  supervision was switched off. State now stands and the watchdog is re-armed.

## 0.3.0

Fan curves, and a safety layer that makes holding a low speed safe under load.

### Added

- **Fan curves per profile.** A profile can now set a different speed for each
  temperature instead of one speed for all of them — 15% at 40 °C, 55% at 70 °C
  — with linear interpolation between the points. Edit them in
  **Settings → Presets**; the chart shows the shape and where the machine
  currently sits on it. Speeds stay percentages of each fan's own range, so a
  curve made on one Mac means the same thing on another. A new built-in
  profile, **Smart**, ships a sensible one.
- **An escalation floor.** Holding fans slower than macOS would is the point of
  this app while the machine is cool, and stops being safe when it is not. Above
  about 65 °C the commanded speed is raised towards full regardless of what was
  asked for, reaching 100% at 90 °C. It is applied as `max(requested, floor)`,
  so it can only ever raise a speed — no curve, slider position or corrupted
  preference can command less. Set 15% and tax the machine and you get 60% at
  80 °C; the slider still reads 15%, because the setting is not rewritten, and
  the dropdown says why the fans are louder than it.
- **A configurable safety cutoff**, in **Settings → General → Safety**. It can be
  **lowered**, never raised: the ceiling is 5 °C below an assumed 100 °C critical
  point, which is also the default, so no reachable setting makes a Mac hotter
  than previous releases allowed. Apple publishes no critical temperature for
  Apple Silicon and no SMC key reports one — all 3222 keys on the development
  machine were checked — so the constant is named `assumedCriticalCelsius` and
  the clamp is enforced in four places, the innermost being `Failsafe` itself.
- **Four new fixed protections**, none configurable: readings that stop updating
  (a control loop dying behind a stale, comfortable-looking number), battery over
  55 °C, storage over 80 °C, and the CPU held above 85 °C for five minutes.
  Nothing watched the battery before — it is excluded from the CPU figure, which
  is correct, but a laptop pinned to a low fan speed can degrade its cells long
  before the die reaches any cutoff. `ProcessInfo.thermalState` is consulted too,
  but only as a supplementary trip: macOS reports `.nominal` when it does not
  know, so it can never be read as evidence of safety.

### Fixed before release

Found by reviewing the above rather than by anyone hitting them; each is covered
by a regression test.

- A **NaN stored speed defeated the safety floor entirely.** `max(.nan, x)`
  returns nan in Swift, because every comparison against nan is false — so a
  corrupted preference beat the floor at every temperature, and the dropdown
  still reported the user's own setting as the driver. Percentages are now
  checked for finiteness on read and again in the controller.
- **The floor was passed through the acoustic deadband**, so the speed actually
  applied could sit several points below what the guard demanded for as long as
  the temperature stayed inside the band. Damping exists to keep the fans quiet
  and does not get a say in the safety floor.
- **The stale-readings trip could never fire.** It compared against a timestamp
  written a few lines earlier in the same function, so the age was always zero.
  It now runs on the poll timer, which still ticks when the thing that wedged is
  the poll queue itself — the only arrangement in which the check means anything.
- **Dragging one curve point flattened the rest of the curve, permanently.**
  Monotonicity was enforced by ratcheting every later point up to match, which is
  right for repairing decoded data and destructive for an edit: raising the first
  point pulled every other point with it, and lowering it again left them raised.
  An edit is now clamped by its neighbours instead of moving them.
- **Editing a curve did nothing until the temperature drifted**, because the
  deadband only commits when the *temperature* moves. Edits apply immediately.
- **One malformed control point discarded every preset.** A decode failure is
  treated as "nothing saved", so an unreadable curve in one profile took the
  whole list with it. An unreadable curve is now dropped on its own and its
  profile survives as a fixed speed.
- A failed hand-back was **swallowed while the UI said control had been
  returned**; the failsafe now reports it.
- Trimming an over-long curve dropped its **hottest** points, lowering the
  maximum — the unsafe direction.
- Decoding bypassed the clamp on a profile's speed, so an out-of-range stored
  value survived and rendered as e.g. "900%".
- The curve editor's Remove button stayed enabled after normalisation collapsed
  the selected point, where it did nothing.

### Changed

- Anti-oscillation is built in and deliberately not exposed: a median prefilter,
  an asymmetric average that adopts rising temperatures at once and decays
  slowly, a deadband drawn around the last committed change rather than around
  curve points, and separate up/down rate limits. Every tool that offers these as
  settings has users who cannot tell whether they are working. The failsafe never
  sees any of it — it reads the raw instantaneous maximum, because a failsafe
  that lags is not a failsafe.
- The Settings window is larger to fit the curve editor.

## 0.2.0

Bug fixes found while reviewing 0.1.0 for wider release.

### Fixed

- **The daemon never handed the fans back before sleep.** It watched for
  `NSWorkspace.willSleepNotification`, which is delivered per user session — and
  a LaunchDaemon has no session, so the observer registered without error and was
  then never called. It now uses `IORegisterForSystemPower`, which is the
  session-independent equivalent, and holds sleep off until the fans are actually
  released. The other restore paths (quit, crash, watchdog, `SIGTERM`) were
  unaffected and had been working throughout.
- **Updating the app left the old background service installed, silently.** The
  service lives outside the app bundle, so replacing `MacFanSpeed.app` never
  touched it and it went on answering requests as if nothing had changed.
  Settings now reports the mismatch and offers **Update Helper…**.
- **A second copy of the app could fight the first over the fans.** Two copies in
  different folders both start and both drive the daemon, so one re-sends its
  target every two seconds while the other tries to release — quitting one
  appeared to do nothing. A second instance now exits at launch.
- **Fan control stayed dead after a transient daemon failure.** Nothing re-tested
  a helper that had stopped answering, so control remained unavailable until
  someone opened Settings and pressed Re-check. The app now retries on its own.
- **Reinstalling the helper while fan control was active failed** with
  `Bootstrap failed: 5: Input/output error`, leaving the new files installed and
  nothing running. `launchctl bootout` returns as soon as the signal is sent, but
  the daemon spends a few seconds handing the fans back to macOS on the way out,
  so the reinstall raced its own shutdown — the busier the daemon, the more
  certain the failure. The installer now waits for the old job to actually go,
  and retries.
- **Replacing the app while it was running broke fan control with no usable
  explanation.** That is the ordinary way people update a Mac app — drag the new
  version in, choose Replace, carry on — and it leaves the old process running
  against a bundle that is no longer its own. The daemon validates its client's
  code signature and rejects it with `errSecCSStaticCodeChanged`, so all the app
  could report was "Couldn't communicate with a helper application", which looks
  like a broken install and sends you to reinstall the helper, which does not
  help. The app now recognises the situation and says to quit and reopen it.
- **Any second client disconnecting released the fans.** The daemon restored
  automatic control whenever *a* client went away, not when the last one did.
  Every `fanctl` command opens its own connection, so running
  `fanctl helper-status` — one of the diagnostics this project asks people to
  paste into bug reports — knocked the fans back to automatic while the app was
  still connected and still holding a preset. The daemon now counts its clients
  and restores only when none are left; the watchdog is unchanged and still
  covers a client that dies without tearing its connection down.
- **A request arriving mid-shutdown could re-force the fans.** The app re-sends
  its target every two seconds, including while the daemon is stopping. Those
  requests queued behind the restore and were then honoured *after* it, setting
  `Ftst` again moments before the process exited, with nothing left running to
  hand the fans back. The daemon now refuses to force a fan once shutdown has
  begun.

### Added

- **Custom mode.** The speed slider is only active under manual control, and the
  only way in was to pick a preset and then notice that moving the slider kept
  you there. Custom names that state and makes it reachable.

### Changed

- Stopped fans read **off** in the menu bar instead of `0`. That is the state an
  idle Mac sits in most of the time, and a bare `0` beside a temperature reads
  like a truncated number. It stays distinct from `----`, which means the speed
  could not be read at all.
- Removing the helper also removes its log at `/var/log/MacFanSpeedHelper.log`.
- The daemon no longer links AppKit; it has no user session to use it in.

## 0.1.0

First release.

- CPU temperature and fan RPM in the menu bar.
- Manual fan control on Apple Silicon, including the `Ftst` firmware unlock that
  M3-and-later machines need before they will accept a fan mode write.
- Presets stored as a percentage of each fan's own range, so they mean the same
  thing on hardware they were not created on.
- Temperature and fan history charts, from 5 minutes to 6 hours.
- A Sensors window listing every hardware temperature the machine exposes,
  grouped and named, with the hardware's own name kept alongside.
- Mandatory 95 °C failsafe, and a watchdog that returns the fans to macOS if the
  app stops responding.
- Start at login, restoring whatever was last set.
