# Changelog

Notable changes in each release. Versions follow [semantic versioning](https://semver.org).

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
