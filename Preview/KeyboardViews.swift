import SwiftUI
import AppKit

// MARK: - Key Types

enum CapturedKey { case space, left, right, info, selectAll, playPause }

// MARK: - Global Key Monitor
//
// Pure event emitter — no routing logic here.
//
// Number keys (object: NSNumber, value = 0–9):
//   .keyDown         — first press
//   .keyUp           — short-press release
//   .keyLongPress    — held past Anim.stripLongPressDelay
//   .keyLongPressEnd — long-press release
//
// Space key (object: SpaceKeyEvent with sessionID):
//   .spaceDown         — first press; sessionID increments each press
//   .spaceUp           — short-press release (sessionID matches its .spaceDown)
//   .spaceLongPressEnd — long-press release  (sessionID matches its .spaceDown)

struct GlobalKeyMonitor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var downMonitor: Any?
        private var upMonitor: Any?

        // Space session
        private var spaceSessionID = 0
        private var spaceTimer: Timer?
        private var spaceDidLongPress = false

        // Number key long-press state
        private var longPressTimer: Timer?
        private var activeKey: Int? = nil
        private var didFireLongPress = false

        private static let numKeyMap: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
            22: 5, 26: 6, 28: 7, 25: 8, 29: 9
        ]

        func install() {
            downMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleDown(event) ?? event
            }
            upMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                self?.handleUp(event) ?? event
            }
        }

        func uninstall() {
            if let m = downMonitor { NSEvent.removeMonitor(m); downMonitor = nil }
            if let m = upMonitor   { NSEvent.removeMonitor(m); upMonitor   = nil }
            spaceTimer?.invalidate(); spaceTimer = nil
            cancelTimer()
        }

        private func handleDown(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == 49 {
                if !event.isARepeat {
                    spaceSessionID += 1
                    spaceDidLongPress = false
                    let sid = spaceSessionID
                    postSpace(.spaceDown, sessionID: sid)
                    spaceTimer?.invalidate()
                    spaceTimer = Timer.scheduledTimer(
                        withTimeInterval: Anim.stripLongPressDelay, repeats: false
                    ) { [weak self] _ in
                        guard let self, self.spaceSessionID == sid else { return }
                        self.spaceDidLongPress = true
                    }
                }
                return nil
            }
            if let key = Self.numKeyMap[event.keyCode], !event.isARepeat {
                activeKey = key
                didFireLongPress = false
                post(.keyDown, key: key)
                longPressTimer?.invalidate()
                longPressTimer = Timer.scheduledTimer(
                    withTimeInterval: Anim.stripLongPressDelay, repeats: false
                ) { [weak self] _ in
                    guard let self, self.activeKey == key else { return }
                    self.didFireLongPress = true
                    self.post(.keyLongPress, key: key)
                }
                return nil
            }
            return event
        }

        private func handleUp(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == 49 {
                spaceTimer?.invalidate(); spaceTimer = nil
                let sid = spaceSessionID
                if spaceDidLongPress {
                    postSpace(.spaceLongPressEnd, sessionID: sid)
                } else {
                    postSpace(.spaceUp, sessionID: sid)
                }
                spaceDidLongPress = false
                return nil
            }
            if let key = Self.numKeyMap[event.keyCode], activeKey == key {
                cancelTimer()
                if didFireLongPress {
                    post(.keyLongPressEnd, key: key)
                } else {
                    post(.keyUp, key: key)
                }
                activeKey = nil
                didFireLongPress = false
                return nil
            }
            return event
        }

        private func cancelTimer() {
            longPressTimer?.invalidate()
            longPressTimer = nil
        }

        private func post(_ name: Notification.Name, key: Int) {
            NotificationCenter.default.post(name: name, object: NSNumber(value: key))
        }

        private func postSpace(_ name: Notification.Name, sessionID: Int) {
            NotificationCenter.default.post(name: name, object: SpaceKeyEvent(sessionID: sessionID))
        }
    }
}

// MARK: - Grid Key Handler (first-responder based)

struct KeyEventView: NSViewRepresentable {
    let onKey: (CapturedKey) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let v = KeyCaptureView()
        v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyCaptureView, context: Context) { nsView.onKey = onKey }
}

// MARK: - Single-Photo Key Handler (global monitor, consumes events)

struct KeyMonitorView: NSViewRepresentable {
    let onKey: (CapturedKey) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start(onKey: onKey)
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onKey: ((CapturedKey) -> Void)?
        private var monitor: Any?

        func start(onKey: @escaping (CapturedKey) -> Void) {
            self.onKey = onKey
            // Space is handled via GlobalKeyMonitor → .keyUp(-1) notification.
            // KeyMonitorView only handles navigation/info/playPause keys here.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let opt = event.modifierFlags.contains(.option)
                switch event.keyCode {
                case 49 where opt:  self.onKey?(.playPause); return nil
                case 123: self.onKey?(.left);   return nil
                case 124: self.onKey?(.right);  return nil
                case 34:  self.onKey?(.info);   return nil
                default:  return event
                }
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}

// MARK: - Undo/Redo + Delete Monitor

struct UndoRedoMonitor: NSViewRepresentable {
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    var onDelete: (() -> Void)? = nil
    var onCmdDelete: (() -> Void)? = nil
    var onToggleSidebar: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = UndoRedoView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? UndoRedoView else { return }
        update(v)
    }

    private func update(_ v: UndoRedoView) {
        v.canUndo         = canUndo
        v.canRedo         = canRedo
        v.onUndo          = onUndo
        v.onRedo          = onRedo
        v.onDelete        = onDelete
        v.onCmdDelete     = onCmdDelete
        v.onToggleSidebar = onToggleSidebar
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? UndoRedoView)?.stop()
    }

    class UndoRedoView: NSView {
        var canUndo    = false
        var canRedo    = false
        var onUndo:          (() -> Void)?
        var onRedo:          (() -> Void)?
        var onDelete:        (() -> Void)?
        var onCmdDelete:     (() -> Void)?
        var onToggleSidebar: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { start() } else { stop() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let cmd = event.modifierFlags.contains(.command)
                switch event.keyCode {
                case 6 where cmd:
                    if event.modifierFlags.contains(.shift) {
                        if self.canRedo { DispatchQueue.main.async { self.onRedo?() }; return nil }
                    } else {
                        if self.canUndo { DispatchQueue.main.async { self.onUndo?() }; return nil }
                    }
                    return event
                case 51 where cmd:
                    if let h = self.onCmdDelete { DispatchQueue.main.async { h() }; return nil }
                    return event
                case 51 where !cmd:
                    if let h = self.onDelete { DispatchQueue.main.async { h() }; return nil }
                    return event
                case 42 where cmd:
                    if let h = self.onToggleSidebar { DispatchQueue.main.async { h() }; return nil }
                    return event
                default:
                    return event
                }
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }
}

// MARK: - First-Responder NSView

class KeyCaptureView: NSView {
    var onKey: ((CapturedKey) -> Void)?
    private var refocusObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            if refocusObserver == nil {
                refocusObserver = NotificationCenter.default.addObserver(
                    forName: .refocusCapture, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, self.window != nil else { return }
                    self.window?.makeFirstResponder(self)
                }
            }
        } else {
            if let obs = refocusObserver {
                NotificationCenter.default.removeObserver(obs)
                refocusObserver = nil
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .refocusCapture, object: nil)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 49:  onKey?(.space)
        case 123: onKey?(.left)
        case 124: onKey?(.right)
        case 34:  onKey?(.info)
        case 0 where cmd: onKey?(.selectAll)
        case 18, 19, 20, 21, 23, 22, 26, 28, 25, 29: break  // number keys: handled by GlobalKeyMonitor
        default:  super.keyDown(with: event)
        }
    }
}
