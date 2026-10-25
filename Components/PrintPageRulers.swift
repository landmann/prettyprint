import SwiftUI

private enum PrintRulerUnit: String {
    case inches = "in"
    case millimetres = "mm"
}

struct PrintPageRulers: View {
    static let thickness: CGFloat = 32
    static let gap: CGFloat = 5
    static let gutterWidth: CGFloat = 48

    static var canvasInsets: CGSize {
        CGSize(width: gutterWidth + gap, height: 2 * (thickness + gap + 8))
    }

    let paper: PrintPaper
    let pageSize: CGSize
    @AppStorage("printRulerUnit") private var unit = PrintRulerUnit.millimetres

    init(paper: PrintPaper, pageSize: CGSize) {
        self.paper = paper
        self.pageSize = pageSize
        _unit = AppStorage(wrappedValue: paper.usesInches ? .inches : .millimetres, "printRulerUnit")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ruler(points: paper.size.width, axis: .horizontal)
                .frame(width: pageSize.width, height: Self.thickness)
                .offset(x: Self.gutterWidth + Self.gap)
            ruler(points: paper.size.height, axis: .vertical)
                .frame(width: Self.gutterWidth, height: pageSize.height)
                .offset(y: Self.thickness + Self.gap)
            HStack(spacing: 1) {
                unitButton(.inches)
                Text("|")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                unitButton(.millimetres)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .frame(width: Self.gutterWidth, height: Self.thickness)
        }
        .frame(
            width: pageSize.width + Self.gutterWidth + Self.gap,
            height: pageSize.height + Self.thickness + Self.gap,
            alignment: .topLeading
        )
    }

    private func ruler(points: CGFloat, axis: Axis) -> some View {
        PrintPageRuler(points: points, usesInches: unit == .inches, axis: axis)
            .allowsHitTesting(false)
    }

    private func unitButton(_ choice: PrintRulerUnit) -> some View {
        Button { unit = choice } label: {
            Text(choice.rawValue)
                .foregroundStyle(unit == choice ? Color.primary : .secondary)
                .padding(.horizontal, 3)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prettyPrintHoverHighlight(.selection)
        .prettyPrintButtonCursor()
        .accessibilityLabel(choice == .inches ? "Measure in inches" : "Measure in millimetres")
        .accessibilityAddTraits(unit == choice ? .isSelected : [])
    }
}

private struct PrintPageRuler: View {
    let points: CGFloat
    let usesInches: Bool
    let axis: Axis

    private var extent: CGFloat { points / 72 * (usesInches ? 1 : 25.4) }

    var body: some View {
        Canvas { context, size in
            let length = axis == .horizontal ? size.width : size.height
            guard length > 0, extent > 0 else { return }
            let scale = length / extent
            let majorStep = labelStep(minimum: 32 / scale)
            let minorStep = usesInches ? majorStep / 4 : labelStep(minimum: majorStep / 5)
            let subdivisions = max(1, Int((majorStep / minorStep).rounded()))
            var ticks = Path()
            for index in 0...Int((extent / minorStep).rounded(.down)) {
                let value = CGFloat(index) * minorStep
                let position = value * scale
                let isMajor = index % subdivisions == 0
                addTick(at: position, depth: isMajor ? 10 : 5, size: size, to: &ticks)
                if isMajor && position > 24 && length - position > 36 {
                    drawLabel(value, at: position, in: size, context: &context)
                }
            }
            addTick(at: length, depth: 10, size: size, to: &ticks)
            let baselineStart = axis == .horizontal
                ? CGPoint(x: 0, y: size.height - 0.5)
                : CGPoint(x: size.width - 0.5, y: 0)
            let baselineEnd = axis == .horizontal
                ? CGPoint(x: length, y: size.height - 0.5)
                : CGPoint(x: size.width - 0.5, y: length)
            ticks.move(to: baselineStart)
            ticks.addLine(to: baselineEnd)
            context.stroke(ticks, with: .color(.secondary.opacity(0.65)), lineWidth: 1)
            drawLabel(0, at: 0, in: size, context: &context, isStart: true)
            drawLabel(extent, at: length, in: size, context: &context, isEnd: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axis == .horizontal ? "Paper width" : "Paper height")
        .accessibilityValue("\(label(extent)) \(usesInches ? "inches" : "millimetres")")
    }

    private func labelStep(minimum: CGFloat) -> CGFloat {
        let steps: [CGFloat] = usesInches
            ? [0.25, 0.5, 1, 2, 5, 10, 20, 50, 100]
            : [1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000]
        return steps.first { $0 >= minimum } ?? max(minimum.rounded(.up), 1)
    }

    private func addTick(at position: CGFloat, depth: CGFloat, size: CGSize, to path: inout Path) {
        if axis == .horizontal {
            path.move(to: CGPoint(x: position, y: size.height - depth))
            path.addLine(to: CGPoint(x: position, y: size.height))
        } else {
            path.move(to: CGPoint(x: size.width - depth, y: position))
            path.addLine(to: CGPoint(x: size.width, y: position))
        }
    }

    private func drawLabel(
        _ value: CGFloat,
        at position: CGFloat,
        in size: CGSize,
        context: inout GraphicsContext,
        isStart: Bool = false,
        isEnd: Bool = false
    ) {
        let text = Text(label(value))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.secondary)
        if axis == .horizontal {
            let anchor: UnitPoint = isStart ? .topLeading : (isEnd ? .topTrailing : .top)
            context.draw(text, at: CGPoint(x: position, y: 2), anchor: anchor)
        } else {
            let anchor: UnitPoint = isStart ? .topTrailing : (isEnd ? .bottomTrailing : .trailing)
            context.draw(text, at: CGPoint(x: size.width - 11, y: position), anchor: anchor)
        }
    }

    private func label(_ value: CGFloat) -> String {
        Double(value).formatted(.number.precision(.fractionLength(0...(usesInches ? 2 : 0))))
    }
}
