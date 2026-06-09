import SwiftUI
import AVKit
import AppKit

// MARK: - AVPlayerLayer Wrapper

/// Raw AVPlayerLayer hosted in NSView — no built-in controls, no gesture conflicts.
/// `opacity` and `cornerRadius` are applied directly on the CALayer so SwiftUI modifiers
/// (which don't reach AVPlayerLayer) are not needed.
struct VideoPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var opacity: Float = 1
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.player = player
        v.setAppearance(opacity: opacity, cornerRadius: cornerRadius)
        return v
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.setAppearance(opacity: opacity, cornerRadius: cornerRadius)
    }

    final class PlayerNSView: NSView {
        var player: AVPlayer? {
            get { playerLayer.player }
            set { playerLayer.player = newValue }
        }

        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        func setAppearance(opacity: Float, cornerRadius: CGFloat) {
            // cornerRadius: no animation needed
            playerLayer.cornerRadius = cornerRadius
            playerLayer.masksToBounds = cornerRadius > 0
            // opacity: animate to match SwiftUI's spring dismiss duration
            guard playerLayer.opacity != opacity else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(Double(Anim.dismissDelay))
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
            playerLayer.opacity = opacity
            CATransaction.commit()
        }
    }
}

// MARK: - Custom Video Controls

/// Single-row controls bar styled close to AVPlayerView's inline controls.
/// Place this with `.overlay(alignment: .bottom)` above the video area.
struct VideoControlsBar: View {
    let player: AVPlayer

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var timeObserver: Any?
    @State private var isMuted = false
    /// Whether the player was playing before scrub began — restored after seek completes.
    @State private var wasPlayingBeforeScrub = false

    private var displayTime: Double { isScrubbing ? scrubValue : currentTime }

    var body: some View {
        controlBar
            .onAppear { attachObserver() }
            .onDisappear { detachObserver() }
    }

    // MARK: Bar Layout

    private var controlBar: some View {
        HStack(spacing: 10) {
            // Play / Pause
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            // Current time
            Text(formatTime(displayTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            // Scrubber
            scrubber

            // Duration
            Text(formatTime(duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            // Mute
            Button(action: toggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    // MARK: Scrubber

    @Environment(\.colorScheme) private var colorScheme

    private var scrubTrackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.15)
    }

    private var scrubFillColor: Color {
        colorScheme == .dark ? Color.white : Color.black.opacity(0.7)
    }

    private var scrubber: some View {
        let filled = duration > 0 ? displayTime / duration : 0
        // Track height only changes during drag; no animation to avoid click flash.
        let trackH: CGFloat = isScrubbing ? 4 : 3
        let thumbD: CGFloat = 14

        return Capsule()
            .fill(scrubTrackColor)
            .frame(height: trackH)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(scrubFillColor)
                        .frame(width: max(0, geo.size.width * CGFloat(filled)), height: trackH)
                }
            }
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let x = max(0, geo.size.width * CGFloat(filled))
                    Circle()
                        .fill(scrubFillColor)
                        .frame(width: thumbD, height: thumbD)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .offset(x: x - thumbD / 2, y: (trackH - thumbD) / 2)
                        .opacity(isScrubbing ? 1 : 0)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !isScrubbing {
                            // Pause on first touch so the player doesn't race the scrub position
                            wasPlayingBeforeScrub = player.timeControlStatus == .playing
                            player.pause()
                            isScrubbing = true
                        }
                        scrubValue = fraction(at: v.location.x) * duration
                    }
                    .onEnded { v in
                        let t = fraction(at: v.location.x) * duration
                        scrubValue = t
                        // isScrubbing stays true until seek lands so timeObserver is blocked
                        // throughout; currentTime only updates after the player is at target.
                        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            guard finished else { return }
                            DispatchQueue.main.async {
                                currentTime = t
                                isScrubbing = false
                                if wasPlayingBeforeScrub { player.play() }
                            }
                        }
                    }
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: WidthKey.self, value: geo.size.width)
                }
            )
    }

    @State private var scrubberWidth: CGFloat = 1

    private func fraction(at x: CGFloat) -> Double {
        let w = scrubberWidth > 1 ? scrubberWidth : 200
        return max(0, min(1, Double(x / w)))
    }

    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    // MARK: Actions

    private func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            // Loop: if at end, restart
            let ct = player.currentTime()
            let dur = player.currentItem?.duration ?? .invalid
            if dur.isValid && dur.isNumeric && ct >= dur - CMTime(seconds: 0.3, preferredTimescale: 600) {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    // MARK: Time Observer

    private func attachObserver() {
        // Duration
        if let item = player.currentItem {
            let d = item.duration
            if d.isValid && d.isNumeric { duration = d.seconds }
        }
        // Periodic update (every ~0.1 s)
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            // Block all state updates while scrubbing — seek completion handler sets currentTime
            // and clears isScrubbing atomically, preventing any intermediate position flash.
            guard !isScrubbing else { return }
            currentTime = time.seconds
            if let d = player.currentItem?.duration, d.isValid, d.isNumeric {
                duration = d.seconds
            }
            isPlaying = player.timeControlStatus == .playing
        }
        isPlaying = player.timeControlStatus == .playing
        isMuted = player.isMuted
    }

    private func detachObserver() {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        timeObserver = nil
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - GIF Player

struct GIFPlayerView: View {
    let content: GIFContent
    @State private var frameIndex = 0

    var body: some View {
        Image(nsImage: content.frames[frameIndex])
            .resizable()
            .scaledToFit()
            .task(id: content.frames.count) {
                guard content.frames.count > 1 else { return }
                while !Task.isCancelled {
                    let delay = content.delays[frameIndex]
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { break }
                    frameIndex = (frameIndex + 1) % content.frames.count
                }
            }
    }
}

// MARK: - Last Frame Snapshot

