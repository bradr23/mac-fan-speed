import XCTest
import SMCKit
@testable import MacFanSpeed

/// Updating the app means replacing `MacFanSpeed.app`. The root daemon lives in
/// `/usr/local/libexec` and survives that untouched, still answering every
/// request exactly as before — so the mismatch is invisible unless something
/// looks for it.
@MainActor
final class HelperVersionTests: XCTestCase {

    func testMatchingVersionsAreNotFlagged() {
        XCTAssertFalse(HelperClient.isOutdated(installed: "0.1.0", bundled: "0.1.0"))
    }

    func testOlderInstalledHelperIsFlagged() {
        XCTAssertTrue(HelperClient.isOutdated(installed: "0.1.0", bundled: "0.2.0"))
    }

    /// Downgrading the app leaves a *newer* daemon installed. That is just as
    /// much a mismatch, and the same button fixes it, so it is reported too.
    func testNewerInstalledHelperIsAlsoFlagged() {
        XCTAssertTrue(HelperClient.isOutdated(installed: "0.3.0", bundled: "0.2.0"))
    }

    /// "Not installed" and "not answering" both arrive as a nil version. Neither
    /// is a version problem, and each has its own message pointing at the right
    /// button, so neither may be reported as out of date.
    func testMissingHelperIsNotReportedAsOutdated() {
        XCTAssertFalse(HelperClient.isOutdated(installed: nil, bundled: "0.2.0"))
    }

    /// The app compares against the version compiled into the helper it ships
    /// with, which is `SMCKit.version` in both. If they ever diverge the check
    /// would fire on a correctly matched pair.
    func testBundledVersionIsTheSharedConstant() {
        XCTAssertEqual(HelperClient().bundledVersion, SMCKit.version)
    }
}
