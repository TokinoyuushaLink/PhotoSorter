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
    var containerHeight: CGFloat = 1
    let onDrag: (CGFloat) -> Void
    let onSettle: (Int) -> Void
    var onVerticalDrag: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)? = nil
    var onVerticalSettle: ((CGFloat) -> Void)? = nil   // passes last-event deltaY as velocity hint

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
        coordinator.containerHeight = containerHeight
        coordinator.onDrag = onDrag
        coordinator.onSettle = onSettle
        coordinator.onVerticalDrag = onVerticalDrag
        coordinator.onVerticalSettle = onVerticalSettle
    }

    // MARK: - Coordinator

    final class Coordinator {
        var containerWidth: CGFloat = 1
        var containerHeight: CGFloat = 1
        var onDrag: ((CGFloat) -> Void)?
        var onSettle: ((Int) -> Void)?
        var onVerticalDrag: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
        var onVerticalSettle: ((CGFloat) -> Void)?
        weak var hostView: NSView?

        private var monitor: Any?
        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0
        private var lastDeltaY: CGFloat = 0
        private var gestureActive = false
        private var lockedAxis: Axis? = nil
        private var lastLockedAxis: Axis? = nil  // remembered through .ended so momentum can be blocked
        private var stopping = false              // set by stop(); monitor self-removes after momentum drains

        private enum Axis { case horizontal, vertical }
        private let axisLockThreshold: CGFloat = 6

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let consume = self.handle(event)
                return consume ? nil : event
            }
        }

        func stop() {
            stopping = true
            // If no vertical momentum is in flight, remove immediately.
            // Otherwise the monitor self-removes after momentumPhase .ended/.cancelled.
            if lastLockedAxis != .vertical {
                if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            }
        }

        private func removeMonitorIfStopping() {
            guard stopping else { return }
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        // Returns true if the event should be consumed (not forwarded to other views).
        @discardableResult
        private func handle(_ event: NSEvent) -> Bool {
            // Momentum events arrive after .ended (phase == [], momentumPhase != []).
            if event.phase == [] {
                guard event.momentumPhase != [] else { return false }
                if lastLockedAxis == .vertical {
                    if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                        lastLockedAxis = nil
                        removeMonitorIfStopping()
                    }
                    return true
                }
                removeMonitorIfStopping()
                return false
            }

            if !gestureActive {
                guard hostView?.window != nil else { return false }
            }

            switch event.phase {
            case .began:
                accumulatedX = 0
                accumulatedY = 0
                lastDeltaY = 0
                lockedAxis = nil
                lastLockedAxis = nil
                gestureActive = true
                return false
            case .changed:
                guard gestureActive else { return false }
                accumulatedX += event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                accumulatedY += dy
                lastDeltaY = dy

                if lockedAxis == nil {
                    if abs(accumulatedX) >= axisLockThreshold || abs(accumulatedY) >= axisLockThreshold {
                        lockedAxis = abs(accumulatedX) >= abs(accumulatedY) ? .horizontal : .vertical
                    }
                }

                switch lockedAxis {
                case .horizontal, nil:
                    let fraction = (accumulatedX / max(containerWidth, 1)).clamped(to: -1...1)
                    onDrag?(fraction)
                    return false
                case .vertical:
                    onDrag?(0)
                    onVerticalDrag?(accumulatedX, accumulatedY)
                    return true
                }
            case .ended, .cancelled:
                guard gestureActive else { return false }
                gestureActive = false
                let wasVertical = lockedAxis == .vertical
                lastLockedAxis = lockedAxis
                switch lockedAxis {
                case .horizontal, nil:
                    let fraction = accumulatedX / max(containerWidth, 1)
                    onSettle?(abs(fraction) >= Anim.gestureThreshold ? (fraction > 0 ? -1 : 1) : 0)
                    onVerticalSettle?(0)
                case .vertical:
                    onSettle?(0)
                    onVerticalSettle?(lastDeltaY)
                }
                accumulatedX = 0
                accumulatedY = 0
                lastDeltaY = 0
                lockedAxis = nil
                return wasVertical
            default:
                return false
            }
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
