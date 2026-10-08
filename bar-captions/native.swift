import AppKit
import CoreGraphics

if CommandLine.arguments.count == 3 {
    let point = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
} else {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    let window = windows.first {
        $0[kCGWindowOwnerName as String] as? String == "Chart QA"
            && ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int == 360
    }!
    print(window[kCGWindowNumber as String]!)
}
