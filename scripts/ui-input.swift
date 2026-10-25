import ApplicationServices
import Foundation

// Compile on the build host; run on the review desktop, including a VM without Swift.
enum Action: String {
    case click, move
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ui-input: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4,
    let action = Action(rawValue: arguments[1]),
    let x = Double(arguments[2]), let y = Double(arguments[3]),
    x.isFinite, y.isFinite
else {
    fail("Usage: ui-input <click|move> X Y (screen points)")
}
guard AXIsProcessTrusted() else {
    fail("Accessibility permission is required on the review desktop.")
}

let point = CGPoint(x: x, y: y)
let events: [CGEventType] =
    action == .click ? [.mouseMoved, .leftMouseDown, .leftMouseUp] : [.mouseMoved]
for type in events {
    guard
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )
    else {
        fail("Could not create a pointer event.")
    }
    event.post(tap: .cghidEventTap)
}

// Posting is asynchronous; keep the sender alive while the desktop receives the events.
Thread.sleep(forTimeInterval: 0.3)
