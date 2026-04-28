import SwiftUI
import AppKit

/// A SwiftUI description of the app icon, rendered at 1024×1024 pt and
/// installed as `NSApp.applicationIconImage` at startup. This sidesteps the
/// need to ship a hand-authored `Assets.xcassets/AppIcon.appiconset` with a
/// dozen PNG sizes.
///
/// The user can replace this with a designed asset catalog later — just
/// remove the `AppIconRenderer.install()` call from `privacycommandApp`
/// and add an asset catalog with the standard icon sizes.
struct AppIconView: View {
    var body: some View {
        ZStack {
            // Background — diagonal indigo→blue gradient. macOS Big Sur+
            // icons are squircles drawn on top of a square; we draw straight
            // onto the 1024×1024 canvas and let the icon mask handle rounding.
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.32, blue: 0.85),
                    Color(red: 0.45, green: 0.27, blue: 0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Big shield centered.
            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white.opacity(0.95))
                .padding(220)

            // Smaller magnifying glass nudged to the bottom-right, suggesting
            // the "audit" action.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.78, blue: 0.27))
                            .frame(width: 360, height: 360)
                            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 220, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .padding(80)
                }
            }
        }
        .frame(width: 1024, height: 1024)
        .clipShape(RoundedRectangle(cornerRadius: 224, style: .continuous))
    }
}

@MainActor
enum AppIconRenderer {

    /// Renders the SwiftUI icon to a `NSImage` and assigns it to
    /// `NSApp.applicationIconImage`. Idempotent — safe to call multiple times.
    static func install() {
        guard let image = makeImage() else { return }
        NSApp.applicationIconImage = image
    }

    static func makeImage() -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView())
        // Match @1x for icon (the 1024 canvas IS the largest needed size).
        renderer.scale = 1.0
        return renderer.nsImage
    }
}
