#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Only the two operations not supplied by the verification AppleScript recipes.
// This is external input and a privacy backdrop, never replacement application UI.
switch CommandLine.arguments.dropFirst().first {
case "backdrop":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let windows = NSScreen.screens.map { screen in
        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
    withExtendedLifetime(windows) { app.run() }
case "click":
    guard CommandLine.arguments.count == 4,
        let x = Double(CommandLine.arguments[2]),
        let y = Double(CommandLine.arguments[3])
    else { fatalError("Usage: native-input click X Y") }
    let point = CGPoint(x: x, y: y)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)
        else { fatalError("Could not create native mouse event") }
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.1)
    }
default:
    fatalError("Usage: native-input backdrop | click X Y")
}
