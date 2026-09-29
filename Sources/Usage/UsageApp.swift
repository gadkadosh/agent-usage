import AppKit
import SwiftUI

@main
struct UsageApp: App {
    var body: some Scene {
        MenuBarExtra("Usage", systemImage: "chart.bar") {
            Text("Usage: not connected yet")
            Divider()
            Button("Quit Usage") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
