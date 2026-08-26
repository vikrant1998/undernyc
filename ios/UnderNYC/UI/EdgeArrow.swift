import SwiftUI

struct EdgeArrow: View {
    let state: EdgeIndicatorState

    var body: some View {
        GeometryReader { proxy in
            let topReserved: CGFloat = 150
            let bottomReserved: CGFloat = 210
            let usableHeight = max(
                proxy.size.height - topReserved - bottomReserved,
                80
            )
            let centerY = topReserved + usableHeight / 2
            let radiusX = max(proxy.size.width / 2 - 48, 0)
            let radiusY = max(usableHeight / 2 - 34, 0)
            let direction = state.angleRadians - .pi / 2
            let x = proxy.size.width / 2 + cos(direction) * radiusX
            let y = centerY + sin(direction) * radiusY
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
