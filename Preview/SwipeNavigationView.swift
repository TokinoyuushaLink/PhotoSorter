import SwiftUI
import AppKit

// Translates trackpad horizontal scroll into a normalized drag fraction [-1, 1],
// then fires a settle callback with direction (-1 / 0 / +1) on gesture end.
//
// Direction convention (natural scroll): finger swipes right → deltaX > 0
// → fraction > 0 → caller shows previous item.
//
// Navigation locking is NOT handled here — the caller (SinglePhotoView) manages
// isNavigating state and queues pending intents in settleGesture().

struct SwipeNavigationView: NSViewRepresentable {
    let containerWidth: CGFloat
    let onDrag: (CGFloat) -> Void
    let onSettle: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        update(coordinator: context.coordinator)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func update(coordinator: Coordinator) {
        coordinator.containerWidth = containerWidth
        coordinator.onDrag = onDrag
        coordinator.onSettle = onSettle
    }

    // MARK: - Coordinator

    final class Coordinator {
        var containerWidth: CGFloat = 1
        var onDrag: ((CGFloat) -> Void)?
        var onSettle: ((Int) -> Void)?
        weak var hostView: NSView?

        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var gestureActive = false

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        private func handle(_ event: NSEvent) {
            if let view = hostView, let _ = view.window {
                let loc = event.locationInWindow
                guard view.convert(view.bounds, to: nil).contains(loc) else { return }
            }
            switch event.phase {
            case .began:
                accumulated = 0
                gestureActive = true
            case .changed:
                guard gestureActive else { return }
                accumulated += event.scrollingDeltaX
                let fraction = (accumulated / max(containerWidth, 1)).clamped(to: -1...1)
                onDrag?(fraction)
            case .ended, .cancelled:
                guard gestureActive else { return }
                gestureActive = false
                let fraction = accumulated / max(containerWidth, 1)
                onSettle?(abs(fraction) >= Anim.gestureThreshold ? (fraction > 0 ? -1 : 1) : 0)
                accumulated = 0
            default:
                break
            }
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
