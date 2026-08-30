import AppKit
import SwiftUI

/// The app's own icon.
///
/// The dropdown header and the About tab both used an SF Symbol, which meant the
/// artwork never appeared anywhere *inside* the app — only in Finder. Someone
/// replacing the icon would see nothing change in the one place they were
/// looking.
///
/// Loaded from the bundle rather than from `NSApp.applicationIconImage`, which
/// depends on application state and returns a placeholder for an accessory app
/// in some contexts. Falls back to the symbol if the bundle has no icon, which
/// is the case when the executable is run directly rather than from the `.app`.
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        if let icon = Self.bundleIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "fan")
                .font(.system(size: size * 0.82))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Resolved once: decoding a 1024 px `.icns` on every view update would be
    /// wasteful in a dropdown that redraws every two seconds.
    private static let bundleIcon: NSImage? = {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: name, withExtension: "icns")
                     ?? Bundle.main.url(forResource: name, withExtension: nil)
        else { return nil }
        return NSImage(contentsOf: url)
    }()
}
