import SwiftUI
import AppKit

// MARK: - Key Types

enum CapturedKey { case space, left, right, info, selectAll }

// MARK: - Grid Key Handler (first-responder based, space key only)

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
    var onShortcut: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start(onKey: onKey, onShortcut: onShortcut)
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.onShortcut = onShortcut
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onKey: ((CapturedKey) -> Void)?
        var onShortcut: ((Int) -> Void)?
        private var monitor: Any?

        private static let numKeyMap: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
            22: 5, 26: 6, 28: 7, 25: 8, 29: 9
        ]

        func start(onKey: @escaping (CapturedKey) -> Void, onShortcut: ((Int) -> Void)?) {
            self.onKey = onKey
            self.onShortcut = onShortcut
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 49:  self.onKey?(.space);  return nil
                case 123: self.onKey?(.left);   return nil
                case 124: self.onKey?(.right);  return nil
                case 34:  self.onKey?(.info);   return nil
                default:
                    if !event.isARepeat, let idx = Self.numKeyMap[event.keyCode], self.onShortcut != nil {
                        DispatchQueue.main.async { self.onShortcut?(idx) }
                        return nil
                    }
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

// MARK: - Number Shortcut Monitor (1–0 → favorite album indices 0–9)

struct NumberShortcutMonitor: NSViewRepresentable {
    let enabled: Bool
    let onShortcut: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ShortcutView()
        v.enabled = enabled
        v.onShortcut = onShortcut
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? ShortcutView else { return }
        v.enabled = enabled
        v.onShortcut = onShortcut
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? ShortcutView)?.stop()
    }

    class ShortcutView: NSView {
        var enabled = true
        var onShortcut: ((Int) -> Void)?
        private var monitor: Any?

        private static let keyMap: [UInt16: Int] = [
            18: 0, 19: 1, 20: 2, 21: 3, 23: 4,
            22: 5, 26: 6, 28: 7, 25: 8, 29: 9
        ]

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { start() } else { stop() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, !event.isARepeat,
                      let idx = Self.keyMap[event.keyCode] else { return event }
                DispatchQueue.main.async { self.onShortcut?(idx) }
                return nil
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
    // Delete key handlers (optional; nil = not handled)
    var onDelete: (() -> Void)? = nil           // Delete key (plain)
    var onCmdDelete: (() -> Void)? = nil        // Cmd+Delete
    var onToggleSidebar: (() -> Void)? = nil    // Cmd+\

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
                case 6 where cmd:   // Cmd+Z / Cmd+Shift+Z
                    if event.modifierFlags.contains(.shift) {
                        if self.canRedo { DispatchQueue.main.async { self.onRedo?() }; return nil }
                    } else {
                        if self.canUndo { DispatchQueue.main.async { self.onUndo?() }; return nil }
                    }
                    return event
                case 51 where cmd:  // Cmd+Delete (keyCode 51 = Delete/Backspace)
                    if let h = self.onCmdDelete { DispatchQueue.main.async { h() }; return nil }
                    return event
                case 51 where !cmd: // plain Delete
                    if let h = self.onDelete { DispatchQueue.main.async { h() }; return nil }
                    return event
                case 42 where cmd:  // Cmd+\ — toggle sidebar (keyCode 42 = backslash)
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
        case 0 where cmd: onKey?(.selectAll)   // ⌘A
        default:  super.keyDown(with: event)
        }
    }
}
