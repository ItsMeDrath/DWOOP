#if os(iOS)
import SwiftUI

/// A simple 1.3-second cold-launch splash using the app's original vector WHOOP wordmark.
struct WhoopOpeningSplashView: View {
    let onFinished: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Drawn as a vector path in code, so it does not depend on how the asset catalog renders the SVG.
                WhoopSplashWordmark()
                    .fill(Color.white)
                    .aspectRatio(WhoopSplashWordmark.aspect, contentMode: .fit)
                    .frame(width: min(geometry.size.width * 0.56, 260))
                    .accessibilityLabel("WHOOP")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                onFinished()
            }
        }
    }
}

/// The WHOOP wordmark (the "WHOOP" letters, without the registered mark), traced from the app's WHOOPWordmark.svg
/// (viewBox 205 x 35). Uses only straight lines and curves, filled with the default non-zero rule like the SVG.
struct WhoopSplashWordmark: Shape {
    /// The drawn width and height in the SVG's own units; the letters end at x = 191.6.
    static let width: CGFloat = 192
    static let height: CGFloat = 35
    static let aspect: CGFloat = width / height

    func path(in rect: CGRect) -> Path {
        let k = rect.width / Self.width
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var p = Path()
        p.move(to: P(56.3721, 0.855469))
        p.addLine(to: P(52.293, 0.855469))
        p.addLine(to: P(52.293, 34.1962))
        p.addLine(to: P(56.3721, 34.1962))
        p.addLine(to: P(56.3721, 0.855469))
        p.closeSubpath()
        p.move(to: P(72.1082, 15.4844))
        p.addLine(to: P(60.4258, 15.4844))
        p.addLine(to: P(60.4258, 19.5652))
        p.addLine(to: P(72.1082, 19.5652))
        p.addLine(to: P(72.1082, 15.4844))
        p.closeSubpath()
        p.move(to: P(80.2627, 0.855469))
        p.addLine(to: P(76.1836, 0.855469))
        p.addLine(to: P(76.1836, 34.1962))
        p.addLine(to: P(80.2627, 34.1962))
        p.addLine(to: P(80.2627, 0.855469))
        p.closeSubpath()
        p.move(to: P(170.727, 34.1962))
        p.addLine(to: P(174.806, 34.1962))
        p.addLine(to: P(174.806, 0.855469))
        p.addLine(to: P(170.727, 0.855469))
        p.addLine(to: P(170.727, 34.1962))
        p.closeSubpath()
        p.move(to: P(184.326, 0.855469))
        p.addLine(to: P(178.859, 0.855469))
        p.addLine(to: P(178.859, 4.82526))
        p.addLine(to: P(184.326, 4.82526))
        p.addCurve(to: P(191.541, 12.4317), control1: P(188.433, 4.93631), control2: P(191.652, 8.35088))
        p.addCurve(to: P(184.326, 19.6495), control1: P(191.43, 16.3738), control2: P(188.266, 19.5385))
        p.addLine(to: P(178.859, 19.6495))
        p.addLine(to: P(178.859, 23.6193))
        p.addLine(to: P(184.326, 23.6193))
        p.addCurve(to: P(195.703, 12.2374), control1: P(190.597, 23.6193), control2: P(195.703, 18.5113))
        p.addCurve(to: P(184.326, 0.855469), control1: P(195.703, 5.96345), control2: P(190.625, 0.855469))
        p.closeSubpath()
        p.move(to: P(104.993, 0.855469))
        p.addCurve(to: P(88.3438, 17.5397), control1: P(95.7806, 0.855469), control2: P(88.3161, 8.32312))
        p.addCurve(to: P(105.021, 34.1962), control1: P(88.3716, 26.7563), control2: P(95.8083, 34.2239))
        p.addCurve(to: P(121.671, 17.5119), control1: P(114.234, 34.1962), control2: P(121.671, 26.7285))
        p.addCurve(to: P(104.993, 0.855469), control1: P(121.643, 8.32312), control2: P(114.206, 0.855469))
        p.closeSubpath()
        p.move(to: P(104.993, 30.2819))
        p.addCurve(to: P(92.2565, 17.5397), control1: P(97.9728, 30.2819), control2: P(92.2565, 24.5632))
        p.addCurve(to: P(104.993, 4.7975), control1: P(92.2565, 10.5162), control2: P(97.9728, 4.7975))
        p.addCurve(to: P(117.73, 17.5397), control1: P(112.014, 4.7975), control2: P(117.73, 10.4885))
        p.addCurve(to: P(104.993, 30.2819), control1: P(117.73, 24.5632), control2: P(112.042, 30.2819))
        p.closeSubpath()
        p.move(to: P(145.474, 0.855469))
        p.addCurve(to: P(128.824, 17.5397), control1: P(136.261, 0.855469), control2: P(128.797, 8.32312))
        p.addCurve(to: P(145.502, 34.1962), control1: P(128.852, 26.7563), control2: P(136.289, 34.2239))
        p.addCurve(to: P(162.151, 17.5119), control1: P(154.714, 34.1962), control2: P(162.151, 26.7285))
        p.addCurve(to: P(145.474, 0.855469), control1: P(162.123, 8.32312), control2: P(154.686, 0.855469))
        p.closeSubpath()
        p.move(to: P(145.474, 30.2819))
        p.addCurve(to: P(132.737, 17.5397), control1: P(138.453, 30.2819), control2: P(132.737, 24.5909))
        p.addCurve(to: P(145.474, 4.7975), control1: P(132.737, 10.4885), control2: P(138.425, 4.7975))
        p.addCurve(to: P(158.211, 17.5397), control1: P(152.494, 4.7975), control2: P(158.211, 10.4885))
        p.addCurve(to: P(145.474, 30.2819), control1: P(158.211, 24.5632), control2: P(152.494, 30.2819))
        p.closeSubpath()
        p.move(to: P(32.4845, 27.7001))
        p.addLine(to: P(28.1556, 13.4589))
        p.addLine(to: P(24.1875, 13.4589))
        p.addLine(to: P(30.5143, 34.1962))
        p.addLine(to: P(34.4547, 34.1962))
        p.addLine(to: P(44.6108, 0.855469))
        p.addLine(to: P(40.6427, 0.855469))
        p.addLine(to: P(32.4845, 27.7001))
        p.closeSubpath()
        p.move(to: P(4.01069, 0.855469))
        p.addLine(to: P(0.0703125, 0.855469))
        p.addLine(to: P(6.36936, 21.5928))
        p.addLine(to: P(10.3375, 21.5928))
        p.addLine(to: P(4.01069, 0.855469))
        p.closeSubpath()
        p.move(to: P(20.3511, 0.855469))
        p.addLine(to: P(10.2227, 34.1962))
        p.addLine(to: P(14.163, 34.1962))
        p.addLine(to: P(24.3192, 0.855469))
        p.addLine(to: P(20.3511, 0.855469))
        p.closeSubpath()
        return p
    }
}
#endif
