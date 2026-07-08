import CoreGraphics
import Foundation
// usage: drag x0 y x1  — left-drag from (x0,y) to (x1,y)
let a = CommandLine.arguments.compactMap { Double($0) }
guard a.count == 3 else { print("usage: drag x0 y x1"); exit(1) }
let (x0, y, x1) = (a[0], a[1], a[2])
func post(_ type: CGEventType, _ x: Double) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.post(tap: .cghidEventTap)
}
post(.leftMouseDown, x0)
usleep(50_000)
let steps = 25
for i in 1...steps {
    post(.leftMouseDragged, x0 + (x1 - x0) * Double(i) / Double(steps))
    usleep(15_000)
}
usleep(50_000)
post(.leftMouseUp, x1)
