#if os(iOS)
import SwiftUI

/// A simple two-second cold-launch splash using the app's original vector WHOOP wordmark.
struct WhoopOpeningSplashView: View {
    let onFinished: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Template mode + an explicit white tint: the SVG's own fills (#ffffffff, CSS styles) can fall back to
                // black in the asset renderer, which left a black wordmark on the black splash.
                Image("WHOOPWordmark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: min(geometry.size.width * 0.56, 260))
                    .accessibilityLabel("WHOOP")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onFinished()
            }
        }
    }
}
#endif
