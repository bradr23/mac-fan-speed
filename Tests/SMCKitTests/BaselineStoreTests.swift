import XCTest
@testable import SMCKit

/// The remembered baseline decides whether forced fans can ever be handed back,
/// and every one of its rules is reachable without hardware. Nothing covered it
/// before; each test here reproduces a defect found by review.
final class BaselineStoreTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        file = directory.appendingPathComponent("baseline.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(bootTime: @escaping () -> Double? = { 1000 }) -> BaselineStore {
        BaselineStore(url: file, bootTime: bootTime)
    }

    private func write(_ json: String) throws {
        try json.data(using: .utf8)!.write(to: file)
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: file.path) }

    // MARK: Round trip

    func testSavesAndReloadsWithinTheSameBoot() {
        var writer = store()
        writer.save([0: 3, 1: 3])

        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3, 1: 3])
    }

    func testClearRemovesTheFile() {
        var writer = store()
        writer.save([0: 3])
        XCTAssertTrue(fileExists)
        writer.clear()
        XCTAssertFalse(fileExists)
    }

    func testMissingFileLoadsEmptyWithoutComplaint() {
        var reader = store()
        XCTAssertEqual(reader.load(), [:])
    }

    // MARK: The forced value is never a baseline

    /// A capture that read a fan mid-manipulation records the forced value.
    /// Persisting it made a transient mis-read permanent: the file outranks live
    /// observation, and restoring "forced" over "forced" never succeeds, so
    /// nothing ever deleted the file that caused it.
    func testRefusesToStoreTheForcedModeValue() {
        var writer = store()
        writer.save([0: FanController.forcedModeValue])
        XCTAssertFalse(fileExists, "a forced mode is not an automatic baseline")
    }

    func testStoresOnlyTheUsableHalfOfAMixedBaseline() {
        var writer = store()
        writer.save([0: 3, 1: FanController.forcedModeValue])

        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3])
    }

    /// A file written by an older build, or hand-edited, gets the same treatment
    /// on the way in.
    func testDropsAForcedValueFoundOnDisk() throws {
        try write(#"{"bootTime":1000,"fans":{"0":3,"1":1}}"#)
        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3])
    }

    func testAFileOfNothingButForcedValuesIsDeleted() throws {
        try write(#"{"bootTime":1000,"fans":{"0":1,"1":1}}"#)
        var reader = store()
        XCTAssertEqual(reader.load(), [:])
        XCTAssertFalse(fileExists)
    }

    func testNonFiniteValuesAreRejected() {
        var writer = store()
        writer.save([0: .nan, 1: .infinity])
        XCTAssertFalse(fileExists)
    }

    // MARK: Staleness

    /// The firmware owns the fans across a restart, so a file from an earlier
    /// boot describes a state that no longer exists — and it outranks the live
    /// modes, which by then are the ground truth.
    func testAFileFromAnEarlierBootIsDiscarded() throws {
        try write(#"{"bootTime":500,"fans":{"0":3}}"#)
        var reader = store(bootTime: { 1000 })
        XCTAssertEqual(reader.load(), [:])
        XCTAssertFalse(fileExists)
    }

    /// "Could not tell" is not "stale". A machine where `kern.boottime` is
    /// unreadable keeps whatever it recorded, because the alternative is losing
    /// the only value that can release the fans.
    func testAnUnknownBootTimeKeepsTheFile() throws {
        try write(#"{"bootTime":500,"fans":{"0":3}}"#)
        var reader = store(bootTime: { nil })
        XCTAssertEqual(reader.load(), [0: 3])
        XCTAssertTrue(fileExists)
    }

    func testAFileWithNoBootStampIsKept() throws {
        try write(#"{"fans":{"0":3}}"#)
        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3])
    }

    func testCorruptContentIsDiscardedRatherThanTrusted() throws {
        try write("not json at all")
        var reader = store()
        XCTAssertEqual(reader.load(), [:])
        XCTAssertFalse(fileExists)
    }

    // MARK: Write volume

    /// The app re-sends every fan's target every two seconds as a watchdog
    /// heartbeat, and each one reached `save`. The baseline cannot change while
    /// control is held, so that was an atomic rewrite of /var/db per fan per
    /// poll — on the daemon's serial queue, ahead of its thermal watch.
    func testRepeatedSavesOfTheSameBaselineWriteOnce() throws {
        var writer = store()
        writer.save([0: 3])
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]

        for _ in 0..<100 { writer.save([0: 3]) }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]

        XCTAssertEqual(first as? Date, after as? Date)
    }

    func testAChangedBaselineIsWrittenAgain() {
        var writer = store()
        writer.save([0: 3])
        writer.save([0: 3, 1: 3])

        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3, 1: 3])
    }

    /// After a clear, the same values must be storable again — otherwise a
    /// restore followed by a fresh session would leave nothing written down.
    func testClearingAllowsTheSameBaselineToBeStoredAgain() {
        var writer = store()
        writer.save([0: 3])
        writer.clear()
        writer.save([0: 3])

        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3])
    }

    // MARK: Read-once

    func testTheFileIsReadOnceEvenIfItChangesUnderneath() throws {
        try write(#"{"bootTime":1000,"fans":{"0":3}}"#)
        var reader = store()
        XCTAssertEqual(reader.load(), [0: 3])

        try write(#"{"bootTime":1000,"fans":{"0":9}}"#)
        XCTAssertEqual(reader.load(), [0: 3], "the baseline must not shift mid-session")
    }
}
