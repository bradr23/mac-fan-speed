import XCTest
@testable import MacFanSpeed
@testable import SMCKit

/// Presets are stored as percentages precisely so they survive moving between
/// Macs with different fan ranges. These pin that down, plus the rules that keep
/// the preset list usable.
@MainActor
final class PresetTests: XCTestCase {

    private func fan(min: Double, max: Double) -> Fan {
        Fan(index: 0, actualRPM: min, minRPM: min, maxRPM: max, targetRPM: min, modeRaw: 3)
    }

    func testSamePresetResolvesDifferentlyPerMachine() {
        // "Cool" has to be sensible on both a narrow and a wide fan range.
        let preset = FanPreset(name: "Cool", percent: 0.35)
        XCTAssertEqual(preset.resolvedRPM(for: fan(min: 2317, max: 7826)), 4245)
        XCTAssertEqual(preset.resolvedRPM(for: fan(min: 1200, max: 3000)), 1830)
    }

    func testBuiltInsSpanTheWholeRange() {
        let f = fan(min: 2000, max: 6000)
        let byID = Dictionary(uniqueKeysWithValues: FanPreset.builtIns.map { ($0.id, $0) })
        XCTAssertEqual(byID[FanPreset.quietID]?.resolvedRPM(for: f), 2000)
        XCTAssertEqual(byID[FanPreset.maxID]?.resolvedRPM(for: f), 6000)
    }

    func testPercentIsClampedOnCreation() {
        XCTAssertEqual(FanPreset(name: "over", percent: 4).percent, 1)
        XCTAssertEqual(FanPreset(name: "under", percent: -2).percent, 0)
    }

    func testResolvedDescriptionCollapsesIdenticalFans() {
        let preset = FanPreset(name: "Half", percent: 0.5)
        let identical = [fan(min: 2000, max: 6000), fan(min: 2000, max: 6000)]
        XCTAssertEqual(preset.resolvedDescription(for: identical), "4000 rpm")
    }

    func testResolvedDescriptionShowsARangeWhenFansDiffer() {
        let preset = FanPreset(name: "Half", percent: 0.5)
        let mixed = [fan(min: 2000, max: 6000), fan(min: 1000, max: 3000)]
        XCTAssertEqual(preset.resolvedDescription(for: mixed), "2000–4000 rpm")
    }

    func testDescriptionWithNoFansFallsBackToPercent() {
        XCTAssertEqual(FanPreset(name: "Half", percent: 0.5).resolvedDescription(for: []), "50%")
    }

    // MARK: Store rules

    func testBuiltInsCannotBeDeleted() {
        // Deleting every preset would leave the mode row with nothing to select.
        let store = PresetStore()
        let builtIn = store.presets.first { $0.isBuiltIn }!
        store.delete(builtIn)
        XCTAssertTrue(store.presets.contains { $0.id == builtIn.id })
    }

    func testCustomPresetsCanBeAddedAndDeleted() {
        let store = PresetStore()
        let added = store.add(name: "Test", percent: 0.6)
        XCTAssertTrue(store.presets.contains { $0.id == added.id })
        store.delete(added)
        XCTAssertFalse(store.presets.contains { $0.id == added.id })
    }

    func testResetRestoresExactlyTheBuiltIns() {
        let store = PresetStore()
        _ = store.add(name: "Scratch", percent: 0.9)
        store.resetToDefaults()
        XCTAssertEqual(store.presets.map(\.id), FanPreset.builtIns.map(\.id))
    }

    // MARK: Rename migration

    func testSavedCoolLapIsRenamedButCustomNamesAreKept() throws {
        // Anyone who edited presets under an earlier build has "Cool Lap" saved.
        // Renaming the built-in in code does not touch data already on disk, so
        // the store migrates it — unless the user chose that name themselves.
        let renamedByUser = FanPreset(
            id: FanPreset.coolID, name: "My Lap Setting", percent: 0.4, isBuiltIn: true
        )
        let stillDefault = FanPreset(
            id: FanPreset.coolID, name: FanPreset.previousCoolName,
            percent: 0.35, isBuiltIn: true
        )

        XCTAssertEqual(migratedName(from: [stillDefault]), "Cool")
        XCTAssertEqual(
            migratedName(from: [renamedByUser]), "My Lap Setting",
            "a name the user chose must survive the migration"
        )
    }

    /// Round-trips presets through the store's own persistence.
    private func migratedName(from presets: [FanPreset]) -> String? {
        let key = "fanPresets"
        let previous = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: key)
        return PresetStore().presets.first { $0.id == FanPreset.coolID }?.name
    }

    func testBuiltInIDsAreStable() {
        // Selection is persisted by id, so changing these would silently orphan
        // whichever preset a user had chosen.
        XCTAssertEqual(
            FanPreset.quietID.uuidString, "00000000-0000-0000-0000-000000000001"
        )
        XCTAssertEqual(
            FanPreset.coolID.uuidString, "00000000-0000-0000-0000-000000000002"
        )
    }
}

@MainActor
/// History range selection, and the downsampling that keeps a six-hour chart
/// from drawing ten thousand points into a 300 pt sparkline.
final class HistoryRangeTests: XCTestCase {

    func testDefaultIsTenMinutes() {
        XCTAssertEqual(HistoryRange.defaultMinutes, 10)
        XCTAssertEqual(HistoryRange.from(minutes: 10), .tenMinutes)
    }

    func testUnknownDurationFallsBackToTheDefault() {
        // A value persisted by a future version must not leave the charts blank.
        XCTAssertEqual(HistoryRange.from(minutes: 999), .tenMinutes)
    }

    func testRangesAreOrderedAndCoverSixHours() {
        let minutes = HistoryRange.allCases.map(\.rawValue)
        XCTAssertEqual(minutes, minutes.sorted(), "buttons should read left to right")
        XCTAssertEqual(HistoryRange.maximumMinutes, 360)
    }

    func testBufferHoldsTheLongestRange() {
        // Switching to 6h must show real history rather than starting empty, so
        // the buffer has to be sized for the longest range on offer.
        let neededSamples = HistoryRange.maximumMinutes * 60 / Int(FanMonitor.pollInterval)
        XCTAssertGreaterThanOrEqual(FanMonitor.historyLimit, neededSamples)
    }
}
