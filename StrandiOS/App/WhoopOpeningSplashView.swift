#if os(iOS)
import SwiftUI

/// A simple two-second cold-launch splash using the app's original vector WHOOP wordmark.
struct WhoopOpeningSplashView: View {
    let onFinished: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                Image("WHOOPWordmark")
                    .resizable()
                    .scaledToFit()
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
