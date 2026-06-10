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
    @State private var isMuted = false
    @State private var scrubberWidth: CGFloat = 1
    /// Whether the player was playing before scrub began — restored after seek completes.
    @State private var wasPlayingBeforeScrub = false

    // Held by the Coordinator so @State copy semantics don't break removeTimeObserver.
    @State private var coordinator = Coordinator()

    private var displayTime: Double { isScrubbing ? scrubValue : currentTime }

    var body: some View {
        controlBar
            .onAppear {
                coordinator.attach(player: player,
                                   onTick: { [self] time, dur, playing in
                    guard !isScrubbing else { return }
                    currentTime = time
                    duration = dur
                    isPlaying = playing
                })
                isPlaying = player.timeControlStatus == .playing
                isMuted = player.isMuted
                if let d = player.currentItem?.duration, d.isValid, d.isNumeric {
                    duration = d.seconds
                }
            }
            .onDisappear { coordinator.detach(from: player) }
    }

    // MARK: Bar Layout

    private var controlBar: some View {
        HStack(spacing: 10) {
            // Play / Pause
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
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
        .padding(.vertical, 6)
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
        let trackH: CGFloat = isScrubbing ? 4 : 3
        let thumbD: CGFloat = 14

        return GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(0, w * CGFloat(filled))
            let thumbX = fillW - thumbD / 2

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(scrubTrackColor)
                    .frame(height: trackH)

                // Fill
                Capsule()
                    .fill(scrubFillColor)
                    .frame(width: fillW, height: trackH)

                // Thumb
                Circle()
                    .fill(scrubFillColor)
                    .frame(width: thumbD, height: thumbD)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: thumbX, y: 0)
                    .opacity(isScrubbing ? 1 : 0)
            }
            .frame(height: thumbD)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        if !isScrubbing {
                            wasPlayingBeforeScrub = player.timeControlStatus == .playing
                            player.pause()
                            isScrubbing = true
                        }
                        scrubValue = max(0, min(1, Double(v.location.x / w))) * duration
                    }
                    .onEnded { v in
                        let t = max(0, min(1, Double(v.location.x / w))) * duration
                        scrubValue = t
                        // isScrubbing clears only after seek completes to prevent position flash.
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
            .onAppear { scrubberWidth = w }
            .onChange(of: w) { _, new in scrubberWidth = new }
        }
        .frame(height: thumbD)
    }

    // MARK: Actions

    private func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
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

    // MARK: Time Observer Coordinator

    /// Holds the opaque observer token so it survives @State value-copy semantics.
    @Observable
    final class Coordinator {
        private var token: Any?

        func attach(player: AVPlayer, onTick: @escaping (Double, Double, Bool) -> Void) {
            guard token == nil else { return }
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                let dur = player.currentItem?.duration
                let durSec = (dur?.isValid == true && dur?.isNumeric == true) ? dur!.seconds : 1.0
                onTick(time.seconds, durSec, player.timeControlStatus == .playing)
            }
        }

        func detach(from player: AVPlayer) {
            if let t = token { player.removeTimeObserver(t); token = nil }
        }
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

