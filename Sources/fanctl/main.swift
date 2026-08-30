import Foundation
import SMCKit

// Debug CLI for the SMC and sensor layer.
// Phase 3 adds the root-only commands: set <rpm>, auto.

let usage = """
usage: fanctl <command>

  fans            list every fan: current, min, max, target, mode
  temps           list CPU temperature sensors
  temps --cpu     hottest CPU sensor only
  temps --dump    every sensor with its key, name and classification (for bug reports)
  sensors         all sensors grouped by what they measure, as the app shows them
  watch           live view, refreshing every 2 seconds
  key <KEY>...    raw value of one or more SMC keys
  version         print version

Requires sudo (writes to the SMC):

  set <rpm>       force every fan to a target speed
  auto            hand every fan back to macOS
  probe-mode      work out what this Mac's fan mode values mean, then restore

Helper daemon (no sudo needed; the daemon is already root):

  helper-status   is the daemon installed and responding?
  helper-set <r>  set targets via the daemon and heartbeat, as the app does
  helper-auto     tell the daemon to release all fans

Fan mode values are not the documented 0=auto/1=forced on Apple Silicon. Run
'probe-mode' once on unfamiliar hardware; it records the resting value, tries a
forced write, reports what changed and always restores the original state.

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fanctl: \(message)\n".utf8))
    exit(1)
}

func monitor() -> SystemMonitor {
    do {
        return try SystemMonitor()
    } catch let error as SMCError {
        fail(error.description)
    } catch {
        fail("\(error)")
    }
}

func fmt(_ value: Double, _ decimals: Int = 0) -> String {
    String(format: "%.\(decimals)f", value)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

// MARK: - Commands

func printFans(_ fans: [Fan]) {
    guard !fans.isEmpty else {
        print("No fans detected. This Mac is passively cooled; monitoring still works.")
        return
    }

    print("\(pad("FAN", 5))\(padLeft("RPM", 8))\(padLeft("MIN", 8))\(padLeft("MAX", 8))\(padLeft("TARGET", 9))\(padLeft("MODE", 6))")
    for fan in fans {
        print(
            pad("\(fan.index)", 5)
            + padLeft(fmt(fan.actualRPM), 8)
            + padLeft(fmt(fan.minRPM), 8)
            + padLeft(fmt(fan.maxRPM), 8)
            + padLeft(fmt(fan.targetRPM), 9)
            + padLeft(fmt(fan.modeRaw), 6)
        )
    }
    print("")
    print("MODE is the raw F{i}Md value. Its meaning is hardware-specific and is")
    print("not the documented 0=auto/1=forced; record the value shown here while")
    print("fans are under macOS control as this Mac's automatic baseline.")
}

func printTemps(_ sensors: [TemperatureSensor], hottest: TemperatureSensor?) {
    let cpu = sensors.filter { $0.tier == .coreCluster || $0.tier == .socDie }
    guard !cpu.isEmpty else {
        print("No CPU temperature sensors identified.")
        print("Run 'fanctl temps --dump' and include the output in a bug report.")
        return
    }

    // Macs expose the same sensor name from several services with slightly
    // different readings; collapse them to the hottest reading per name.
    var hottestByName: [String: Double] = [:]
    for sensor in cpu {
        hottestByName[sensor.name] = max(hottestByName[sensor.name] ?? -.infinity, sensor.celsius)
    }

    for name in hottestByName.keys.sorted() {
        print("\(pad(name, 26))\(padLeft(fmt(hottestByName[name]!, 1), 7)) °C")
    }
    if let hottest {
        print("")
        print("hottest CPU: \(fmt(hottest.celsius, 1)) °C  (\(hottest.name))")
    }
}

func printDump(_ sensors: [TemperatureSensor], hottest: TemperatureSensor?) {
    print("Machine: \(machineModel())")
    print("macOS:   \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Sensors: \(sensors.count)")
    print("")
    guard !sensors.isEmpty else {
        print("No temperature sensors readable at all.")
        print("The HID sensor interface may be unavailable on this system.")
        return
    }
    // Everything needed to add support for this machine: the hardware's own
    // name, the SMC key behind it, what the app called it, and how it was
    // classified. Paste-able straight into an issue.
    print("\(pad("SENSOR", 24))\(pad("KEY", 6))\(padLeft("°C", 7))  "
        + "\(pad("NAMED AS", 30))CLASSIFIED")
    for sensor in sensors {
        let named = SensorNaming.name(for: sensor)
        print(pad(sensor.name, 24)
            + pad(sensor.smcKey ?? "-", 6)
            + padLeft(fmt(sensor.celsius, 1), 7) + "  "
            + pad(named.isVerbatim ? "(unrecognised)" : named.display, 30)
            + "\(sensor.tier)")
    }
    let unrecognised = sensors.filter { SensorNaming.name(for: $0).isVerbatim }
    if !unrecognised.isEmpty {
        print("")
        print("\(Set(unrecognised.map(\.name)).count) sensor name(s) not recognised. "
            + "Please include this output in a bug report so they can be named.")
    }
    print("")
    if let hottest {
        print("hottest CPU: \(fmt(hottest.celsius, 1)) °C (\(hottest.name), tier \(hottest.tier))")
    } else {
        print("hottest CPU: unavailable — no sensor matched any tier")
    }
}

func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func watch(_ mon: SystemMonitor) {
    let snapshot = mon.snapshot()
    let fanCount = snapshot.fans.count

    var header = "\(pad("TIME", 10))\(padLeft("CPU °C", 8))"
    for fan in snapshot.fans { header += padLeft("FAN\(fan.index)", 8) }
    print(header)

    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"

    // Ctrl-C is the intended exit.
    while true {
        let snap = mon.snapshot()
        var line = pad(formatter.string(from: Date()), 10)
        line += padLeft(snap.cpuTemperature.map { fmt($0.celsius, 1) } ?? "--", 8)
        for i in 0..<fanCount {
            let rpm = snap.fans.first { $0.index == i }.map { fmt($0.actualRPM) } ?? "--"
            line += padLeft(rpm, 8)
        }
        print(line)
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2.0)
    }
}

// MARK: - Write probe

/// Test whether the firmware unlock sequence makes fan control possible.
///
/// From the M3 generation onward `thermalmonitord` holds the fans in mode 3 and
/// the firmware refuses `F{i}Md` writes with error 0x82 (130) — exactly what a
/// Mac16,8 does. Setting `Ftst = 1` asks the firmware to yield. This probes that
/// sequence end to end and always puts the machine back, including `Ftst = 0`.
///
/// The target is above the current fan speed, so the probe only ever cools the
/// machine harder.
func probeMode(_ mon: SystemMonitor) {
    let controller = mon.makeController()
    controller.captureBaseline()

    guard let fan = mon.fans().first else {
        print("This Mac has no fans; nothing to probe.")
        return
    }

    print("Machine: \(machineModel())   macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("")
    printFans(mon.fans())
    let baselineMode = controller.baseline(forFan: fan.index) ?? fan.modeRaw
    print("")
    print("Ftst (firmware unlock) before: "
        + ((try? mon.rawKey("Ftst"))?.number.map { fmt($0) } ?? "unreadable"))

    // Whatever happens, hand everything back.
    defer {
        print("")
        print("=== Restoring ===")
        for index in mon.fans().map(\.index) {
            _ = controller.rawWrite(fanIndex: index, field: .target, value: 0)
            _ = controller.rawWrite(fanIndex: index, field: .mode, value: baselineMode)
        }
        // Clearing Ftst is the one restore that must not be allowed to fail
        // quietly: it is what hands thermal management back to the firmware.
        if let error = controller.relock(force: true) {
            print("  !! could not clear Ftst: \(error)")
        }
        // The firmware takes a moment to resume control; give it one.
        Thread.sleep(forTimeInterval: 3)
        let ftst = controller.unlockKeyValue() ?? -1
        printFans(mon.fans())
        print("Ftst after restore: \(fmt(ftst))"
            + (ftst == 0 ? "  — firmware is back in control" : "  ** STILL SET — run: sudo fanctl auto **"))
    }

    func attempt(_ label: String, _ field: FanWritableField, _ value: Double) -> Bool {
        let error = controller.rawWrite(fanIndex: fan.index, field: field, value: value)
        print("  \(pad(label, 34)) \(error == nil ? "accepted" : "REFUSED — \(error!)")")
        return error == nil
    }

    // ---- Step 1: without the unlock, to confirm the baseline behaviour -------
    print("")
    print("=== Without unlock (expected to fail on this hardware) ===")
    let lockedModeWrite = attempt("F\(fan.index)Md = 1", .mode, 1)

    // ---- Step 2: unlock, then retry -----------------------------------------
    print("")
    print("=== With Ftst = 1 ===")
    guard attempt("Ftst = 1", .testUnlock, 1) else {
        print("")
        print("CONCLUSION: the firmware refused the unlock itself. Fan control is")
        print("not available on this machine.")
        return
    }

    // Retry rather than sleep-then-try-once: the firmware yields somewhere in a
    // window, and a single attempt at a guessed moment misses it.
    print("  retrying the mode write until the firmware yields "
        + "(up to \(fmt(FanController.unlockRetryWindow))s)…")

    var unlockedModeWrite = false
    var landedAfter: TimeInterval = 0
    for index in mon.fans().map(\.index) {
        do {
            let elapsed = try controller.forceModeWithRetry(fanIndex: index)
            print("    F\(index)Md = 1  accepted after \(String(format: "%.1f", elapsed))s")
            unlockedModeWrite = true
            landedAfter = max(landedAfter, elapsed)
        } catch {
            print("    F\(index)Md = 1  REFUSED for the whole window — \(error)")
        }
    }
    if let now = mon.fans().first(where: { $0.index == fan.index }) {
        print("    mode now reads \(fmt(now.modeRaw))")
    }
    _ = landedAfter

    // ---- Step 3: does the target alone steer the fan? ------------------------
    // With Ftst set, the previous run showed the firmware parking the fans at
    // their minimum and setting targets we never wrote. If it now honours our
    // target, that is fan control regardless of the mode key.
    let target = fan.rpm(forPercent: 0.55)
    print("")
    print("=== Applying a target to every fan ===")
    for index in mon.fans().map(\.index) {
        _ = attempt("F\(index)Tg = \(fmt(target))", .target, target)
    }
    print("  observing for 14s…")
    var peak = 0.0
    for step in 1...7 {
        Thread.sleep(forTimeInterval: 2)
        if let now = mon.fans().first(where: { $0.index == fan.index }) {
            peak = max(peak, now.actualRPM)
            print("    +\(step * 2)s  rpm=\(fmt(now.actualRPM))  "
                + "target=\(fmt(now.targetRPM))  mode=\(fmt(now.modeRaw))")
        }
    }

    print("")
    print("CONCLUSION")
    print("  mode write without unlock:  \(lockedModeWrite ? "accepted" : "refused")")
    print("  mode write with unlock:     \(unlockedModeWrite ? "accepted" : "refused")")
    print("  requested target:           \(fmt(target)) rpm")
    print("  fan peaked at:              \(fmt(peak)) rpm")
    print("")
    // The firmware parks fans near minimum on its own once unlocked, so beating
    // idle is not enough — the fan has to approach what we actually asked for.
    let followedTarget = peak > target * 0.75
    let movedAtAll = peak > 500
    if followedTarget {
        print("  FAN CONTROL WORKS: the fan followed the requested target.")
        print("  Sequence: Ftst = 1, then retry F{i}Md until it lands, then F{i}Tg.")
        print("  Ftst must stay set for as long as manual control is held.")
    } else if movedAtAll {
        print("  Partial: the fans spun up but did not reach the requested speed.")
        print("  This is likely the firmware's own minimum after yielding, not our")
        print("  target being honoured. Compare the peak against \(fmt(fan.minRPM)) rpm.")
    } else {
        print("  The fans did not move. Control is not available by this route.")
    }
}

// MARK: - Dispatch

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "version":
    print("fanctl \(SMCKit.version)")

case "fans":
    printFans(monitor().fans())

case "temps":
    let mon = monitor()
    let sensors = mon.sensors()
    let hottest = mon.hottestCPU()

    if args.contains("--dump") {
        printDump(sensors, hottest: hottest)
    } else if args.contains("--cpu") {
        guard let hottest else {
            fail("no CPU temperature sensor identified; try 'fanctl temps --dump'")
        }
        print("\(fmt(hottest.celsius, 1)) °C  (\(hottest.name))")
    } else {
        printTemps(sensors, hottest: hottest)
    }

case "watch":
    watch(monitor())

case "key":
    guard args.count >= 2 else { fail("usage: fanctl key <SMC-KEY>") }
    let mon = monitor()
    for key in args.dropFirst() {
        do {
            let value = try mon.rawKey(key)
            let hex = value.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let decoded = value.number.map { fmt($0, 2) } ?? "(not decoded)"
            let attrs = String(format: "0x%02x", value.attributes)
            print("\(key)  type='\(value.type)'  size=\(value.bytes.count)  "
                + "attrs=\(attrs) [\(value.attributeDescription)]  "
                + "raw=[\(hex)]  value=\(decoded)")
        } catch let error as SMCError {
            print("\(key)  \(error.description)")
        } catch {
            print("\(key)  \(error)")
        }
    }

case "set":
    guard args.count >= 2, let rpm = Double(args[1]) else {
        fail("usage: sudo fanctl set <rpm>")
    }
    guard FanController.isRoot else { fail(FanControlError.notRoot.description) }

    let mon = monitor()
    let controller = mon.makeController()
    controller.captureBaseline()

    let fans = mon.fans()
    guard !fans.isEmpty else { fail("this Mac has no fans") }

    var anyAccepted = false
    for fan in fans {
        do {
            let result = try controller.setTarget(fanIndex: fan.index, rpm: rpm)
            var line = "fan \(fan.index): requested \(fmt(result.requestedRPM))"
            if result.wasClamped {
                line += ", clamped to \(fmt(result.clampedRPM)) "
                      + "(range \(fmt(fan.minRPM))–\(fmt(fan.maxRPM)))"
            }
            line += result.targetAccepted ? "  [accepted]" : "  [NOT ACCEPTED by the SMC]"
            print(line)
            anyAccepted = anyAccepted || result.targetAccepted
        } catch {
            print("fan \(fan.index): \(error)")
        }
    }
    print("")
    if anyAccepted {
        print("Fans are now forced. Run 'sudo fanctl auto' to hand them back to macOS.")
    } else {
        // Saying "fans are now forced" after every write was refused would be a
        // lie, and a dangerous one — it implies a state that needs undoing.
        print("No fan accepted a target; nothing was changed.")
        print("Run 'sudo fanctl probe-mode' to find out what this SMC will accept.")
        exit(1)
    }

case "auto":
    guard FanController.isRoot else { fail(FanControlError.notRoot.description) }

    let mon = monitor()
    let controller = mon.makeController()
    controller.captureBaseline()

    let failures = controller.restoreAllAutomatic()
    if failures.isEmpty {
        print("All fans returned to automatic control.")
        print("(the firmware sets the mode itself once Ftst is cleared)")
        let ftst = (try? mon.rawKey("Ftst"))?.number ?? -1
        print("Ftst (firmware unlock) = \(fmt(ftst))"
            + (ftst == 0 ? "  — firmware is back in control" : "  ** SHOULD BE 0 **"))
        printFans(mon.fans())
    } else {
        for (index, message) in failures.sorted(by: { $0.key < $1.key }) {
            print("fan \(index): \(message)")
        }
        exit(1)
    }

case "probe-mode":
    guard FanController.isRoot else { fail(FanControlError.notRoot.description) }
    probeMode(monitor())

case "sensors":
    // Same grouping and naming the app's Sensors window shows, for anyone who
    // would rather stay in the terminal.
    let mon = monitor()
    let groups = SensorReading.byCategory(mon.sensors())
    guard !groups.isEmpty else {
        print("No temperature sensors readable.")
        exit(1)
    }
    for group in groups {
        print("")
        print(group.category.title.uppercased())
        for reading in group.readings {
            var line = "  " + pad(reading.displayName, 34)
                     + padLeft(fmt(reading.celsius, 1) + " °C", 9)
            var detail = [reading.name]
            if let key = reading.smcKey { detail.append(key) }
            if reading.sourceCount > 1 { detail.append("x\(reading.sourceCount)") }
            line += "   " + detail.joined(separator: " · ")
            print(line)
        }
    }

case "keys":
    // Enumerate what this Mac actually offers, rather than probing a list we
    // already know. Writable keys are what matter when looking for a control path.
    let mon = monitor()
    let filter = args.count > 1 ? args[1].uppercased() : nil
    let names = mon.allKeyNames()
    print("This SMC exposes \(names.count) keys.")
    if let filter { print("Showing those containing '\(filter)':") }
    print("")
    print("\(pad("KEY", 7))\(pad("TYPE", 7))\(pad("ATTRS", 8))FLAGS")

    var writable: [String] = []
    for name in names {
        if let filter, !name.uppercased().contains(filter) { continue }
        guard let value = try? mon.rawKey(name) else { continue }
        if value.isWritable { writable.append(name) }
        print("\(pad(name, 7))\(pad(value.type, 7))"
            + "\(pad(String(format: "0x%02x", value.attributes), 8))"
            + "\(value.attributeDescription)")
    }
    print("")
    if writable.isEmpty {
        print("No writable keys matched.")
    } else {
        print("Writable: \(writable.joined(separator: ", "))")
    }

case "helper-status":
    let helper = HelperConnection()
    guard helper.isInstalled else {
        print("Helper is NOT installed.")
        print("Install it with: sudo ./scripts/install-helper.sh")
        exit(1)
    }
    if let version = helper.version() {
        print("Helper is installed and responding: \(version)")
    } else {
        print("Helper is installed but NOT responding.")
        print("Check /var/log/MacFanSpeedHelper.log")
        exit(1)
    }

case "helper-auto":
    let helper = HelperConnection()
    if let error = helper.setAllAuto() {
        fail("helper: \(error)")
    }
    print("Helper returned all fans to automatic control.")
    printFans(monitor().fans())

case "helper-set":
    // Sets targets through the daemon and then heartbeats, exactly as the app
    // does. Killing this process is how the watchdog gets tested: with no
    // heartbeat the daemon must hand the fans back on its own.
    guard args.count >= 2, let rpm = Double(args[1]) else {
        fail("usage: fanctl helper-set <rpm>   (hold it open; Ctrl-C to stop)")
    }
    let mon = monitor()
    let helper = HelperConnection()
    guard helper.isInstalled else { fail("helper is not installed") }

    for fan in mon.fans() {
        if let error = helper.setFan(index: fan.index, rpm: rpm) {
            print("fan \(fan.index): \(error)")
        } else {
            print("fan \(fan.index): target \(fmt(rpm)) rpm sent via helper")
        }
    }
    print("")
    print("Heartbeating every 2s. Ctrl-C to release fans; kill -9 to test the watchdog.")

    // Release on a clean exit. A kill -9 deliberately skips this.
    signal(SIGINT) { _ in
        _ = HelperConnection().setAllAuto()
        print("\nReleased fans to automatic control.")
        exit(0)
    }
    while true {
        Thread.sleep(forTimeInterval: 2)
        _ = helper.heartbeat()
    }

case nil, "help", "--help", "-h":
    print(usage)

default:
    FileHandle.standardError.write(Data("fanctl: unknown command '\(args[0])'\n".utf8))
    print(usage)
    exit(2)
}
