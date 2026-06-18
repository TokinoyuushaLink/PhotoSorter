import SwiftUI
import AppKit
import ImageIO

extension Notification.Name {
    static let refreshRequested            = Notification.Name("PhotoSorterRefresh")
    static let refocusCapture              = Notification.Name("PhotoSorterRefocusCapture")
    static let autoHideStripToggled        = Notification.Name("PhotoSorterAutoHideStripToggled")
    static let videoLoopToggled            = Notification.Name("PhotoSorterVideoLoopToggled")
    static let thumbnailFitToggled         = Notification.Name("PhotoSorterThumbnailFitToggled")
    static let appShouldTerminateWithConfirm = Notification.Name("PhotoSorterTerminateConfirm")
    static let sortedSelectionShouldClear    = Notification.Name("PhotoSorterClearSortedSelection")
    static let confirmDeletePending          = Notification.Name("PhotoSorterConfirmDeletePending")
    static let sortedViewShouldDismiss       = Notification.Name("PhotoSorterSortedViewDismiss")
    static let assetsDidSort                 = Notification.Name("PhotoSorterAssetsDidSort")
    static let clearFavoritesRequested       = Notification.Name("PhotoSorterClearFavorites")
    static let clearRecentRequested          = Notification.Name("PhotoSorterClearRecent")

    // GlobalKeyMonitor raw events
    // Number keys (object: NSNumber, value = 0–9):
    static let keyDown         = Notification.Name("PhotoSorterKeyDown")
    static let keyUp           = Notification.Name("PhotoSorterKeyUp")
    static let keyLongPress    = Notification.Name("PhotoSorterKeyLongPress")
    static let keyLongPressEnd = Notification.Name("PhotoSorterKeyLongPressEnd")
    // Space key (object: SpaceKeyEvent):
    static let spaceDown         = Notification.Name("PhotoSorterSpaceDown")
    static let spaceUp           = Notification.Name("PhotoSorterSpaceUp")           // short press release
    static let spaceLongPressEnd = Notification.Name("PhotoSorterSpaceLongPressEnd") // long press release
}

/// Payload for space-key notifications. sessionID ties a keyUp/keyLongPressEnd back to its keyDown.
struct SpaceKeyEvent {
    let sessionID: Int
}

enum Prefs {
    static let autoHideStrip     = "ps.autoHideStripInSingleMode"
    static let sidebarVisible    = "ps.sidebarVisible"
    static let hasPendingDeletes = "ps.hasPendingDeletes"
    static let videoLoop         = "ps.videoLoop"
    static let thumbnailFit      = "ps.thumbnailFit"
    static let photoLibraryPath  = "ps.photoLibraryPath"
}

enum PhotoLibrary {
    static var derivativesBase: String? {
        UserDefaults.standard.string(forKey: Prefs.photoLibraryPath)
            .map { "\($0)/resources/derivatives" }
    }
    static var mastersBase: String? {
        UserDefaults.standard.string(forKey: Prefs.photoLibraryPath)
            .map { "\($0)/resources/derivatives/masters" }
    }
}

// PHImageManager on macOS returns NSImage backed by NSCGImageSnapshotRep whose CGImage
// origin is bottom-left (Quartz). SwiftUI uses top-left, causing a vertical flip.
// Redrawing into NSBitmapImageRep normalizes the coordinate system.
func normalizeForSwiftUI(_ image: NSImage) -> NSImage {
    let size = image.size
    guard size.width > 0, size.height > 0,
          !image.representations.allSatisfy({ $0 is NSBitmapImageRep }) else { return image }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return image }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let result = NSImage(size: size)
    result.addRepresentation(rep)
    return result
}

/// Runs `body` with all SwiftUI animations disabled.
func withoutAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}

// MARK: - Grid Layout

@Observable final class GridLayout {
    var cols: Int = 2
    var cellSize: CGFloat = 0
    var spacing: CGFloat = 2
    var originX: CGFloat = 0
    var originY: CGFloat = 0
    var scrollOffset: CGFloat = 0
    // Set by PhotoCollectionView coordinator once makeNSView runs
    var scrollToVisible: ((Int) -> Void)?
    /// Returns the global screen frame for the item with the given asset ID.
    /// Falls back to frameFor(index:) when not set (uncategorized mode).
    var frameForID: ((String) -> CGRect)?

    func frameFor(index: Int) -> CGRect {
        guard cellSize > 0, cols > 0 else { return .zero }
        let row = index / cols
        let col = index % cols
        return CGRect(
            x: originX + CGFloat(col) * (cellSize + spacing),
            y: originY + CGFloat(row) * (cellSize + spacing) + scrollOffset,
            width: cellSize, height: cellSize
        )
    }
}

// MARK: - GIF Content

struct GIFContent {
    let frames: [NSImage]
    let delays: [Double]

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [NSImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let img = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))
            frames.append(normalizeForSwiftUI(img))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
            let gif   = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                     ?? gif?[kCGImagePropertyGIFDelayTime as String] as? Double
                     ?? 0.1
            delays.append(max(delay, 0.02))
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.delays = delays
    }
}

// MARK: - Layout Constants

enum Layout {
    // Grid
    static let columnWidth: CGFloat             = 220
    static let gridMinCellWidth: CGFloat        = 143
    static let thumbnailSize                    = CGSize(width: 320, height: 320)
    static let previewSize                      = CGSize(width: 960, height: 960)
    static let previewBatchSize                 = 5
    static let previewBatchDelay: TimeInterval  = 0.15
    static let recentAlbumsMaxCount             = 20
    static let fallbackScreenSize               = CGSize(width: 2560, height: 1600)

    // Single-photo card animation
    static let cardCornerRadius: CGFloat        = 6
    static let cardFallbackSizeRatio: CGFloat   = 0.2
    static let cardSourceFrameMinWidth: CGFloat = 4

    // Content view overlay geometry
    static let topGradientHeight: CGFloat       = 88
    static let stripHeight: CGFloat             = 40
    static let stripFadeHeight: CGFloat         = 56

    // Window
    static let windowInitialSize                = CGSize(width: 1100, height: 720)
    static let windowMinSize                    = CGSize(width: 800, height: 560)
    static let titlebarAreaHeight: CGFloat      = 38    // titlebar row height used by overlay frames
    static let videoTriggerHeight: CGFloat      = 56    // video controls hover zone height
    static let sortedSectionHeaderHeight: CGFloat = 48  // non-first section header height in sorted view

    // Album strip chips
    static let chipHeight: CGFloat              = 26
    static let chipSpacing: CGFloat             = 6
    static let chipHorizontalInset: CGFloat     = 8
    static let chipKeyLabelSize: CGFloat        = 9
    static let stripRowHeight: CGFloat          = 40
    static let stripHoverTriggerHeight: CGFloat = 50

    // Section header
    static let sectionHeaderFontSize: CGFloat   = 32
    static let sectionHeaderTrashSize: CGFloat  = 18
    static let sectionHeaderTrashButtonSize: CGFloat = 28
}

// MARK: - Animation Constants

enum Anim {
    static let enter         = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let dismiss       = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let gestureSettle = Animation.spring(response: 0.28, dampingFraction: 0.88)
    static let gestureCancel = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let videoFadeIn   = Animation.easeIn(duration: 0.15)

    static let enterDelayMs:           UInt64       = 30
    static let mediaReadyDelayMs:      UInt64       = 630   // spring(response:0.42) settles ~650ms
    static let dismissDelay:           TimeInterval = 0.35
    static let gestureThreshold:       CGFloat      = 0.05
    static let dismissDragThreshold:   CGFloat      = 0.35  // fraction of height at which backdrop fully fades
    static let dismissDragMinPx:         CGFloat      = 30   // minimum downward drag to register as dismiss intent
    static let dismissVelocityThreshold: CGFloat     = 4    // per-event deltaY (pts) counted as a fast flick
    static let dismissDragOpacityFloor:  CGFloat     = 0.3  // backdrop never goes below this during drag (only dismiss anim reaches 0)

    // UI feedback
    static let hintDuration:       TimeInterval = 2.5   // top hint auto-dismiss
    static let fadeInOut:          TimeInterval = 0.2   // generic crossfade
    static let fastFade:           TimeInterval = 0.15  // title gradient threshold crossfade
    static let multiHintFade:      TimeInterval = 0.4   // multi-queue hint fade

    // Collection animations
    static let batchUpdateDuration:   TimeInterval = 0.28  // NSCollectionView batch delete/insert
    static let dragSettleDuration:    TimeInterval = 0.2   // strip drag reorder cell slide
    static let dragCommitDuration:    TimeInterval = 0.15  // strip drag commit snap-back
    static let stripLongPressDelay:   TimeInterval = 0.4   // number key held → strip highlight

    // Column browser highlight
    static let columnHighlightDelay:  TimeInterval = 0.13  // show highlight after assign
    static let columnClearDelay:      TimeInterval = 0.11  // clear highlight after show
}

// MARK: - Stable NSTrackingArea wrapper

struct TrackingAreaView: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = TrackingNSView()
        v.onHover = onHover
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingNSView)?.onHover = onHover
    }

    private class TrackingNSView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent)  { onHover?(false) }
    }
}
