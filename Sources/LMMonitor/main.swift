import Foundation
// No @main anywhere else. SwiftUI's App.main() is public, so we can gate it.
let args = CommandLine.arguments
if args.contains("--selftest") { exit(SelfTest.run()) }
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let secs = (i + 2 < args.count ? Double(args[i + 2]) : nil) ?? 12
    MainActor.assumeIsolated { SnapshotMode.run(outputDir: args[i + 1], seconds: secs) }
}
LMMonitorApp.main()
