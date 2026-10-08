import AppKit
import CoreGraphics

// External input/backdrop helper only. The UI under test is the packaged release app.
if CommandLine.arguments[1] == "backdrop" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSScreen.main!.visibleFrame,
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .windowBackgroundColor
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    app.run()
} else if CommandLine.arguments[1] == "tokens" {
    print("\(Int(CommandLine.arguments[2])!.formatted()) tokens")
} else {
    let point = CGPoint(
        x: Double(CommandLine.arguments[2])!, y: Double(CommandLine.arguments[3])!)
    CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left
    )?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left
    )?.post(tap: .cghidEventTap)
}
