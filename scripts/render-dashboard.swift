// Run from the repository root; see docs/screenshots/README.md.
import AppKit
import SwiftUI

@main
struct DashboardScreenshots {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/agent-usage-screenshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for remaining in [100, 75, 50, 25, 10, 0] {
                try capture(
                    snapshot: snapshot(session: Double(remaining), weekly: Double(remaining)),
                    scheme: scheme,
                    destination: output.appendingPathComponent("remaining-\(remaining)-\(name).png")
                )
            }
            try capture(
                snapshot: snapshot(session: 75, weekly: 50), scheme: scheme,
                destination: output.appendingPathComponent("dashboard-\(name).png")
            )
        }
    }

    private static func snapshot(session: Double, weekly: Double) -> UsageSnapshot {
        UsageSnapshot(limits: UsageLimits(rateLimit: .init(
            primaryWindow: .init(usedPercent: 100 - session, resetAfterSeconds: 3_720),
            secondaryWindow: .init(usedPercent: 100 - weekly, resetAfterSeconds: 90_000)
        )), fetchedAt: .now)
    }

    @MainActor
    private static func capture(snapshot: UsageSnapshot, scheme: ColorScheme, destination: URL) throws {
        let panel = UsagePanel(
            snapshot: snapshot, error: nil, isRefreshing: false,
            onRefresh: {}, onQuit: {}
        )
        .environment(\.colorScheme, scheme)
        .background(Color(NSColor(calibratedWhite: scheme == .dark ? 0.15 : 0.96, alpha: 1)))

        let host = NSHostingView(rootView: panel)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CaptureError.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngUnavailable
        }
        try png.write(to: destination)
        print(destination.path)
    }

    private enum CaptureError: Error {
        case bitmapUnavailable
        case pngUnavailable
    }
}
