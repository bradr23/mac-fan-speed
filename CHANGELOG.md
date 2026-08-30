# Changelog

Notable changes in each release. Versions follow [semantic versioning](https://semver.org).

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
