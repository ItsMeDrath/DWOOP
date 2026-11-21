#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// A two-second, full-screen cold-launch animation. The bundled clip is cropped from the
/// supplied reference so it contains only the original animated WHOOP mark on black.
struct WhoopOpeningSplashView: View {
    let onFinished: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    SplashPlayerLayer(player: player)
                        .aspectRatio(2, contentMode: .fit)
                        .frame(width: min(geometry.size.width * 0.78, 320))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear(perform: startPlayback)
        .onDisappear {
            player?.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === player?.currentItem else { return }
            onFinished()
        }
    }

    private func startPlayback() {
        guard let url = Bundle.main.url(forResource: "WhoopOpeningSplash", withExtension: "mp4") else {
            // A missing optional visual asset must never block entry to the app.
            onFinished()
            return
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause
        player = newPlayer
        newPlayer.play()
    }
}

private struct SplashPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

private final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
#endif
