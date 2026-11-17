import AVKit
import SwiftUI

/// AppKit `AVPlayerView` wrapper. SwiftUI's `VideoPlayer` relies on the `_AVKit_SwiftUI`
/// cross-import overlay, which aborts at launch in SwiftPM-built app bundles.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none // playback is driven by the editor's own controls and timeline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
