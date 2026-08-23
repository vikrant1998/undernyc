import SwiftUI

struct EdgeArrow: View {
    let state: EdgeIndicatorState

    var body: some View {
        GeometryReader { proxy in
            let radiusX = max(proxy.size.width / 2 - 42, 0)
            let radiusY = max(proxy.size.height / 2 - 110, 0)
            let direction = state.angleRadians - .pi / 2
            let x = proxy.size.width / 2 + cos(direction) * radiusX
            let y = proxy.size.height / 2 + sin(direction) * radiusY
            VStack(spacing: 3) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 31, weight: .bold))
                    .rotationEffect(.radians(state.angleRadians))
                Text(state.line)
                    .font(.caption.bold())
            }
            .foregroundStyle(Color(uiColor: UIColor(hex: state.color)))
            .padding(9)
            .background(.ultraThinMaterial, in: Circle())
            .position(x: x, y: y)
        }
        .ignoresSafeArea()
    }
}

/// A heading-only guide. Unlike the 3D edge indicator, pitch and roll cannot
/// make this arrow orbit around the display.
struct CompassArrow: View {
    let line: String
    let color: String
    let deltaDegrees: Double

    var body: some View {
        GeometryReader { proxy in
            let aligned = abs(deltaDegrees) < 8
            let pointsRight = deltaDegrees > 0
            let x = aligned
                ? proxy.size.width / 2
                : (pointsRight ? proxy.size.width - 54 : 54)
            let y = aligned ? proxy.size.height * 0.34 : proxy.size.height / 2
            VStack(spacing: 2) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 27, weight: .bold))
                    .rotationEffect(.degrees(aligned ? 0 : (pointsRight ? 90 : -90)))
                Text(
                    aligned
                        ? "\(line) AHEAD"
                        : "\(line) · \(Int(abs(deltaDegrees).rounded()))°"
                )
                    .font(.caption2.bold().monospaced())
            }
            .foregroundStyle(Color(uiColor: UIColor(hex: color)))
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.14), lineWidth: 0.75)
            }
            .position(x: x, y: y)
        }
        .ignoresSafeArea()
    }
}
