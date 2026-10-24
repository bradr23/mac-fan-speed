import XCTest
@testable import MacFanSpeed

/// The menu bar title republishes only on a real change.
///
/// `@Published` fires on every assignment, equal or not, and each one rebuilt
/// the `MenuBarExtra` label and pushed a scene update through Control Center —
/// 65,560 of them in 35 hours on the developer's machine for a string that was
/// usually identical to the one already on screen.
@MainActor
final class MenuBarLabelTests: XCTestCase {

    func testStartsEmpty() {
        XCTAssertEqual(MenuBarLabel().text, "")
    }

    func testFirstUpdateIsPublished() {
        let label = MenuBarLabel()
        label.update(to: "42° off")
        XCTAssertEqual(label.text, "42° off")
    }

    func testRepeatingTheSameTextDoesNotRepublish() {
        let label = MenuBarLabel()
        var publishes = 0
        let token = label.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        label.update(to: "42° off")
        for _ in 0..<100 { label.update(to: "42° off") }

        XCTAssertEqual(publishes, 1, "a poll that changes nothing must not redraw the title")
        XCTAssertEqual(label.text, "42° off")
    }

    func testEachRealChangePublishesOnce() {
        let label = MenuBarLabel()
        var publishes = 0
        let token = label.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        for text in ["42° off", "42° off", "43° off", "43° off", "42° off"] {
            label.update(to: text)
        }

        XCTAssertEqual(publishes, 3)
        XCTAssertEqual(label.text, "42° off")
    }
}
