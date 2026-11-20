import SwiftUI

struct HalftoneBackdrop: View {
    private static let paper = Color(red: 0.09, green: 0.09, blue: 0.11)
    private static let ink = Color(red: 0.25, green: 0.55, blue: 1).opacity(0.22)
    private static let dotSpacing: CGFloat = 7
    private static let grainCount = 7000

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.paper))
            Self.drawDots(in: &context, size: size)
            Self.drawGrain(in: &context, size: size)
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private static func drawDots(in context: inout GraphicsContext, size: CGSize) {
        let reach = hypot(size.width, size.height)
        guard reach > 0 else { return }
        var row = 0
        var y = -dotSpacing
        while y < size.height + dotSpacing {
            var x: CGFloat = row.isMultiple(of: 2) ? 0 : dotSpacing / 2
            while x < size.width + dotSpacing {
                let distance = hypot(size.width - x, y) / reach
                let radius = max(0, 1 - distance * 1.25) * dotSpacing * 0.52
                if radius > 0.2 {
                    let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: dot), with: .color(ink))
                }
                x += dotSpacing
            }
            y += dotSpacing * 0.866
            row += 1
        }
    }

    private static func drawGrain(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var generator = GrainGenerator(state: 7)
        for _ in 0..<grainCount {
            let x = CGFloat.random(in: 0..<size.width, using: &generator)
            let y = CGFloat.random(in: 0..<size.height, using: &generator)
            let isLight = Bool.random(using: &generator)
            let strength = Double.random(in: 0...(isLight ? 0.06 : 0.2), using: &generator)
            let speck = Path(CGRect(x: x, y: y, width: 1, height: 1))
            context.fill(speck, with: .color((isLight ? Color.white : Color.black).opacity(strength)))
        }
    }
}

private struct GrainGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var mixed = state
        mixed ^= mixed >> 33
        mixed = mixed &* 0xff51afd7ed558ccd
        mixed ^= mixed >> 33
        return mixed
    }
}
