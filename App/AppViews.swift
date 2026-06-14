import SwiftUI
import AppKit

// MARK: - Resize Divider

enum DividerSide { case left, right }

struct ResizeDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let side: DividerSide

    @State private var isDragging = false
    @State private var startX: CGFloat = 0
    @State private var startWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    startX = value.startLocation.x
                                    startWidth = width
                                }
                                let delta = side == .left
                                    ? value.location.x - startX
                                    : startX - value.location.x
                                width = max(minWidth, min(maxWidth, startWidth + delta))
                            }
                            .onEnded { _ in isDragging = false }
                    )
            )
    }
}

// MARK: - Movable Title Bar Background

/// 透明垫层：mouseDownCanMoveWindow = true，让未被子视图命中的点击传回窗口拖动。
struct MovableTitleBarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = _MovableView()
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private class _MovableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - View Extensions

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
