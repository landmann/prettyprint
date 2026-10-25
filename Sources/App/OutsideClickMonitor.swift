import AppKit

struct OutsideClickTracker {
    static let dragThreshold: CGFloat = 4

    private var pressLocation: CGPoint?
    private var isDragging = false

    mutating func shouldClose(after type: NSEvent.EventType, at location: CGPoint) -> Bool {
        switch type {
        case .leftMouseDown:
            pressLocation = location
            isDragging = false
            return false
        case .leftMouseDragged:
            if let start = pressLocation, hypot(location.x - start.x, location.y - start.y) > Self.dragThreshold {
                isDragging = true
            }
            return false
        case .leftMouseUp:
            defer { pressLocation = nil; isDragging = false }
            return pressLocation != nil && !isDragging
        case .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class OutsideClickMonitor {
    private var monitor: Any?
    private var tracker = OutsideClickTracker()

    func start(onOutsideClick: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let type = event.type
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.tracker.shouldClose(after: type, at: location) else { return }
                onOutsideClick()
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tracker = OutsideClickTracker()
    }
}
