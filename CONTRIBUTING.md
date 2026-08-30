# Contributing

Thanks for looking. This is a small, deliberately conservative project: it can
make a laptop run hotter than Apple intends, so the safety rules below are not
negotiable.

## Building

Requires Xcode Command Line Tools. Full Xcode is only needed for `swift test`.

```bash
./scripts/build.sh release   # build everything, assemble and sign build/MacFanSpeed.app
./scripts/run.sh             # build, kill any running copy, launch
swift test                   # unit tests
./scripts/release.sh         # versioned archive in dist/
```

There is no Xcode project, and none should be added — the app builds with Swift
Package Manager and `scripts/build.sh` assembles the bundle by hand.

## Testing on your Mac

```bash
sudo ./scripts/verify-fan-control.sh   # SMC writes, the daemon, crash recovery, clamping
./scripts/verify-safety.sh             # presets and the temperature failsafe
```

Both restore your fans on every exit path, including Ctrl-C. `verify-safety.sh`
temporarily lowers the failsafe threshold and puts the real one back afterwards,
verifying that it did.

The `fanctl` tool exercises the same layer without the UI:

```bash
./build/fanctl fans temps sensors watch
./build/fanctl temps --dump          # paste this into an issue
sudo ./build/fanctl probe-mode       # what your firmware accepts; self-restoring
sudo ./build/fanctl auto             # hand the fans back to macOS
```

Two environment variables help when a menu bar app is awkward to drive:
`MFS_SELFTEST=1` runs a headless check and exits, `MFS_PREVIEW=1` opens the
dropdown in an ordinary window.

## Safety rules

These are binding. [SPEC.md](SPEC.md) explains the reasoning behind each.

1. The only SMC keys this project writes are `F{i}Md`, `F{i}Tg` and `Ftst`.
   `FanWritableField` makes anything else structurally unexpressible — keep it
   that way.
2. Every exit path — quit, crash, watchdog, sleep, stopping the daemon — ends
   with the fans under macOS control **and `Ftst` cleared**. Leaving `Ftst` set
   hands thermal management to a process that may no longer exist.
3. The temperature failsafe is mandatory and **not user-raisable**. The ceiling
   is 5 °C below `Failsafe.assumedCriticalCelsius` and is also the default, so
   nothing a user can do makes a machine hotter than a stock install allows. It
   outranks every route into manual control, including restoring a saved preset
   at launch. `Failsafe.clampTrip` is the layer this rests on — the slider's
   range and the settings clamps are conveniences on top of it.
3a. The escalation floor (`ThermalGuard`) is hardcoded and applied as
   `max(requested, floor)` to every manual path. `max` is monotone, so no curve,
   slider position or corrupted preference can command a speed below it. It is a
   *speed* mechanism inside manual control; the failsafe is a *mode* mechanism
   that leaves it. Keep them separate — a bug in one must not disable the other.
4. Losing temperature readings while fans are forced also returns them to macOS.
   Holding a manual speed blind is worse than giving up control.
5. **Never assume hardware.** Fan count, RPM ranges, sensor names and even the
   existence of the firmware unlock are read at runtime. Fanless Macs are a
   supported state. Speeds are percentages of each fan's range, never fixed RPM.
6. Sensors that are not measurements — the `tcal` calibration constant and the
   `tdev` family — must never feed the failsafe.

## Adding support for a Mac

Most gaps are sensor names. If a Mac shows temperatures as unavailable or lists
sensors under "Other", run:

```bash
./build/fanctl temps --dump
```

That prints every sensor with its SMC key, what the app named it, and how it was
classified. Adding a name is usually one line in `SensorNaming.swift`, plus a
test in `RealHardwareNamesTests.swift` using the exact observed string.

The rule for naming is **rename, never invent**. Translate a name only where the
hardware's own name says what it measures. `PMU tdie1` means "a die sensor" and
nothing more, so it becomes "Processor die 1" — not "CPU core 1", which would be
a guess presented as fact. An unrecognised name shown verbatim is better than a
plausible wrong one.

## The app icon

`Resources/AppIcon.png` is the master artwork. Rebuild everything derived from it
with:

```bash
swift scripts/make-icon.swift
```

That writes `Resources/AppIcon.icns` for the app and `docs/icon.png` for the
README, so the two cannot drift. Both are committed; the script only needs
running when the artwork changes.

Two things it does that are easy to miss when replacing the artwork:

- **Insets to Apple's grid.** macOS puts an icon's shape in 824 points of a 1024
  canvas and leaves the rest transparent for the system's shadow. Full-bleed
  artwork looks oversized beside real apps in Finder. `MFS_ICON_SCALE=1` keeps
  artwork that already has its own margin.
- **Cuts the corners transparent.** Artwork exported without an alpha channel has
  opaque black outside the rounded square, which reads as a black *square* on a
  light background. Keying on the colour is not an option — this icon has
  thousands of pure-black pixels in the middle of the design — so the corners are
  cut geometrically. `MFS_ICON_CORNER=0` for artwork that is not a rounded square.

## Cutting a release

Releases are built by CI, not by hand — nothing binary is ever committed to the
repository.

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist` and `SMCKit.version` in `Sources/SMCKit/SMCKit.swift`.
   The short version and `SMCKit.version` must match; `scripts/release.sh`
   refuses to build if they disagree.

   `SMCKit.version` is also what the app compares against the installed daemon to
   detect a stale helper, so bumping it is what makes existing users see the
   **Update Helper** prompt. Do not leave it behind.
2. Add a `## <version>` section to `CHANGELOG.md`. The release workflow copies it
   into the release notes; without it the release publishes with install
   boilerplate only and the build logs a warning.
3. Commit, then tag and push:

   ```bash
   git tag v0.2.0 && git push origin v0.2.0
   ```

`.github/workflows/release.yml` then builds on an Apple Silicon runner, checks
the tag agrees with the bundle version, and publishes a GitHub release with the
`.app` archive and its checksum attached.

`scripts/release.sh` produces the same archive locally if you need one.

## Licence

MIT. By contributing you agree your work ships under it.
