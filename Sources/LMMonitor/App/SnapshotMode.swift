import SwiftUI
import AppKit

/// `LMMonitor --snapshot <dir> [seconds]`: runs the real data pipeline headless for a few
/// seconds, then renders the popover sections with live data to PNGs (dark + light) and exits.
/// Useful for bug reports and for checking the UI without clicking the menu bar.
@MainActor
enum SnapshotMode {
    private static var delegate: AppDelegate?

    static func run(outputDir: String, seconds: Double) -> Never {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        let out = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                MetricsStore.shared.popoverOpen = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    render(to: out)
                    d.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    exit(0)
                }
            }
        }
        app.run()
        exit(0)
    }

    private static func render(to dir: URL) {
        let store = MetricsStore.shared
        let pages: [(String, AnyView)] = [
            ("menubar", AnyView(MenuBarLabel(store: store).font(.system(size: 13)).padding(4))),
            ("top", AnyView(VStack(spacing: 10) { HeaderView(); LiveCardView(); VitalsStripView() })),
            ("overview", AnyView(TabContentView(tab: .overview))),
            ("system", AnyView(TabContentView(tab: .system))),
            ("history", AnyView(TabContentView(tab: .history))),
            ("alerts", AnyView(TabContentView(tab: .alerts))),
        ]
        for scheme in [ColorScheme.dark, .light] {
            for (name, view) in pages {
                let content = view
                    .padding(12)
                    .frame(width: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environmentObject(store)
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: content)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: file)
                print("wrote \(file.path)")
            }
        }
    }
}
