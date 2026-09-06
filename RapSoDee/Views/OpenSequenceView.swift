import SwiftUI
import AVFoundation
import AppKit

/// Full-window muse open sequence — cream stage, centered movie, skippable.
/// Uses AVPlayerLayer (not SwiftUI VideoPlayer) to avoid AVPlayerView demangle crash on some SDKs.
struct OpenSequenceView: View {
    var onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var contentOpacity: Double = 1
    @State private var didFinish = false

    /// Cream matching the clip background (slightly warmer than Muse paper).
    private let cream = Color(red: 0.965, green: 0.945, blue: 0.910)

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()

            if let player {
                OpenSequencePlayerView(player: player)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 24, y: 8)
                    .padding(40)
                    .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { finish(reason: "tap") }
        }
        .opacity(contentOpacity)
        .focusable()
        .onKeyPress(.escape) {
            finish(reason: "escape")
            return .handled
        }
        .onKeyPress(.space) {
            finish(reason: "space")
            return .handled
        }
        .onAppear(perform: start)
        .onDisappear(perform: teardown)
        .accessibilityLabel("RapSoDee open sequence")
        .accessibilityHint("Press Escape, Space, or click to skip")
    }

    private func start() {
        guard let url = OpenSequenceController.videoURL else {
            finish(reason: "missing")
            return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = false
        player = p

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            finish(reason: "ended")
        }

        item.asset.loadValuesAsynchronously(forKeys: ["playable"]) {
            var error: NSError?
            let status = item.asset.statusOfValue(forKey: "playable", error: &error)
            DispatchQueue.main.async {
                if status == .failed || (status == .loaded && !item.asset.isPlayable) {
                    finish(reason: "unplayable")
                    return
                }
                p.play()
            }
        }
    }

    private func finish(reason: String) {
        guard !didFinish else { return }
        didFinish = true
        _ = reason
        player?.pause()
        OpenSequenceController.markSeen()
        withAnimation(.easeOut(duration: 0.35)) {
            contentOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            teardown()
            onFinished()
        }
    }

    private func teardown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
    }
}

/// Thin AppKit bridge — AVPlayerLayer only, no AVPlayerView.
private struct OpenSequencePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.wantsLayer = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerLayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
