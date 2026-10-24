import Foundation

/// The menu bar title, as an observable of its own.
///
/// `MenuBarExtra`'s label is rebuilt whenever anything the scene observes
/// changes, and the poll republishes four properties every two seconds — fans,
/// cpu, allSensors, samples. The title, rounded to whole degrees and to the
/// nearest hundred rpm, changes far less often than that.
///
/// Each rebuild pushes a scene update through Control Center. On the
/// developer's machine that was 65,560 log entries in 35 hours, almost all of
/// them re-publishing a string identical to the one already on screen.
///
/// Splitting the title into an object with one property, and assigning it only
/// when it genuinely differs, means the label re-renders when the text changes
/// and not when the readings behind it do.
@MainActor
final class MenuBarLabel: ObservableObject {
    @Published private(set) var text: String = ""

    /// Assigns only on a real change. `@Published` fires on every assignment,
    /// equal or not, so the comparison has to happen here rather than being
    /// left to SwiftUI's diffing — by the time SwiftUI could diff it, the scene
    /// update has already gone out.
    func update(to newText: String) {
        guard newText != text else { return }
        text = newText
    }
}
