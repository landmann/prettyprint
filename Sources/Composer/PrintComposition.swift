import CoreGraphics
import Foundation

struct PrintPaper: Equatable {
    let name: String
    let size: CGSize
    let usesInches: Bool

    static let a4 = PrintPaper(name: "A4", size: CGSize(width: 595, height: 842), usesInches: false)
    static let letter = PrintPaper(name: "Letter", size: CGSize(width: 612, height: 792), usesInches: true)

    static var localDefault: PrintPaper {
        Locale.current.measurementSystem == .us ? .letter : .a4
    }

    private static let namedSizes: [String: (CGFloat, CGFloat, Bool)] = [
        "a3": (842, 1191, false), "a4": (595, 842, false), "a5": (420, 595, false), "a6": (298, 420, false),
        "b5": (516, 729, false), "letter": (612, 792, true), "legal": (612, 1008, true),
        "tabloid": (792, 1224, true), "executive": (522, 756, true), "env10": (297, 684, true),
    ]

    init?(pageSizeName: String) {
        let suffix = pageSizeName.lastIndex(of: ".").map { pageSizeName[pageSizeName.index(after: $0)...] }
        let base = suffix.map { $0.allSatisfy(\.isLetter) ? String(pageSizeName.dropLast($0.count + 1)) : pageSizeName } ?? pageSizeName
        let lowered = base.lowercased()
        if let (width, height, usesInches) = Self.namedSizes[lowered] {
            self.init(name: base, size: CGSize(width: width, height: height), usesInches: usesInches)
            return
        }
        let points = lowered.wholeMatch(of: #/w(\d+(?:\.\d+)?)h(\d+(?:\.\d+)?)/#)
        let dimensions = (lowered.split(separator: "_").last.map(String.init) ?? lowered)
            .wholeMatch(of: #/(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)(in|mm)?/#)
        let size: CGSize
        let usesInches: Bool
        if let points, let width = Double(points.1), let height = Double(points.2) {
            size = CGSize(width: width, height: height)
            usesInches = true
        } else if let dimensions, let width = Double(dimensions.1), let height = Double(dimensions.2) {
            usesInches = dimensions.3 != "mm"
            let scale = usesInches ? 72 : 72 / 25.4
            size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        } else {
            return nil
        }
        guard size.width > 0, size.height > 0 else { return nil }
        self.init(name: base, size: size, usesInches: usesInches)
    }

    init(name: String, size: CGSize, usesInches: Bool) {
        self.name = name
        self.size = size
        self.usesInches = usesInches
    }

    var bounds: CGRect {
        CGRect(origin: .zero, size: size)
    }

    func fittedSize(in bounds: CGSize) -> CGSize {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func formattedSize(_ size: CGSize) -> String {
        if usesInches {
            return String(format: "%.2f × %.2f in", size.width / 72, size.height / 72)
        }
        return String(format: "%.0f × %.0f mm", size.width / 72 * 25.4, size.height / 72 * 25.4)
    }
}

enum PrintItemAspect: Hashable, CaseIterable, Identifiable, Codable {
    case original
    case free
    case square
    case landscape4x3
    case portrait3x4
    case landscape3x2
    case portrait2x3

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Original"
        case .free: "Free"
        case .square: "1:1"
        case .landscape4x3: "4:3"
        case .portrait3x4: "3:4"
        case .landscape3x2: "3:2"
        case .portrait2x3: "2:3"
        }
    }

    func ratio(sourceAspect: CGFloat) -> CGFloat? {
        switch self {
        case .original: sourceAspect
        case .free: nil
        case .square: 1
        case .landscape4x3: 4.0 / 3.0
        case .portrait3x4: 3.0 / 4.0
        case .landscape3x2: 3.0 / 2.0
        case .portrait2x3: 2.0 / 3.0
        }
    }
}

enum PrintItemContent: Equatable, Codable {
    case file(URL)
    case text(PrintText)
}

struct PrintCompositionItem: Identifiable, Equatable, Codable {
    let id: UUID
    var content: PrintItemContent
    var pageIndex: Int
    var sourceAspect: CGFloat
    var frame: CGRect
    var aspect: PrintItemAspect
    var rotation: Double

    init(
        id: UUID = UUID(),
        content: PrintItemContent,
        pageIndex: Int = 0,
        sourceAspect: CGFloat,
        frame: CGRect,
        aspect: PrintItemAspect = .original,
        rotation: Double = 0
    ) {
        self.id = id
        self.content = content
        self.pageIndex = pageIndex
        self.sourceAspect = sourceAspect
        self.frame = frame
        self.aspect = aspect
        self.rotation = PrintCompositionGeometry.normalized(degrees: rotation)
    }

    var sourceURL: URL? {
        if case .file(let url) = content { return url }
        return nil
    }

    var text: PrintText? {
        if case .text(let text) = content { return text }
        return nil
    }

    var lockedRatio: CGFloat? {
        aspect.ratio(sourceAspect: sourceAspect)
    }
}

struct PrintComposition: Equatable {
    var paper: PrintPaper
    var items: [PrintCompositionItem]

    static func single(
        sourceURL: URL,
        sourceAspect: CGFloat,
        paper: PrintPaper,
        pageIndex: Int = 0
    ) -> PrintComposition {
        PrintComposition(
            paper: paper,
            items: [
                PrintCompositionItem(
                    content: .file(sourceURL),
                    pageIndex: pageIndex,
                    sourceAspect: sourceAspect,
                    frame: PrintCompositionGeometry.fitted(
                        aspect: sourceAspect,
                        in: paper.bounds
                    )
                )
            ]
        )
    }

    func adapted(to newPaper: PrintPaper) -> PrintComposition {
        guard newPaper != paper else { return self }

        let scale = min(
            newPaper.size.width / paper.size.width,
            newPaper.size.height / paper.size.height
        )
        let offset = CGPoint(
            x: (newPaper.size.width - paper.size.width * scale) / 2,
            y: (newPaper.size.height - paper.size.height * scale) / 2
        )

        return PrintComposition(
            paper: newPaper,
            items: items.map { item in
                var item = item
                if var text = item.text {
                    text.fontSize *= scale
                    item.content = .text(text)
                }
                item.frame = CGRect(
                    x: offset.x + item.frame.minX * scale,
                    y: offset.y + item.frame.minY * scale,
                    width: item.frame.width * scale,
                    height: item.frame.height * scale
                )
                return item
            }
        )
    }
}

struct PrintCompositionSelection {
    let items: [PrintCompositionItem]
    let frame: CGRect
    let rotation: Double

    init?(items: [PrintCompositionItem], rotation: Double) {
        guard let first = items.first else { return nil }
        self.items = items
        if items.count == 1 {
            frame = first.frame
            self.rotation = first.rotation
            return
        }
        self.rotation = rotation
        let points = items.flatMap { item in
            PrintCompositionCorner.allCases.map {
                PrintCompositionGeometry.rotate(
                    PrintCompositionGeometry.corner($0, of: item.frame, rotation: item.rotation),
                    around: .zero, degrees: -rotation
                )
            }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!,
                            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let center = PrintCompositionGeometry.rotate(
            CGPoint(x: bounds.midX, y: bounds.midY), around: .zero, degrees: rotation
        )
        frame = CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
                       width: bounds.width, height: bounds.height)
    }

    var lockedRatio: CGFloat? {
        items.count == 1 ? items[0].lockedRatio : frame.width / frame.height
    }

    func transformed(to target: CGRect, rotation targetRotation: Double) -> [PrintCompositionItem] {
        let scale = target.width / frame.width
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let delta = targetRotation - rotation
        return items.map { original in
            var item = original
            let rotated = PrintCompositionGeometry.rotate(
                CGPoint(x: original.frame.midX, y: original.frame.midY), around: center, degrees: delta
            )
            let width = original.frame.width * scale, height = original.frame.height * scale
            item.frame = CGRect(
                x: target.midX + (rotated.x - center.x) * scale - width / 2,
                y: target.midY + (rotated.y - center.y) * scale - height / 2,
                width: width, height: height
            )
            item.rotation = PrintCompositionGeometry.normalized(degrees: original.rotation + delta)
            if var text = item.text {
                text.fontSize *= scale
                item.content = .text(text)
            }
            return item
        }
    }
}

enum PrintCompositionCorner: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.minX : rect.maxX, y: isTop ? rect.minY : rect.maxY)
    }

    func opposite(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeft ? rect.maxX : rect.minX, y: isTop ? rect.maxY : rect.minY)
    }
}

struct PrintSnapGuides: Equatable {
    var vertical: CGFloat?
    var horizontal: CGFloat?
}

struct PrintCompositionGrid {
    static let lineCountRange = 0...50

    var verticalLineCount = 3
    var horizontalLineCount = 3

    func verticalLines(in paper: CGSize) -> [CGFloat] {
        positions(count: verticalLineCount, length: paper.width)
    }

    func horizontalLines(in paper: CGSize) -> [CGFloat] {
        positions(count: horizontalLineCount, length: paper.height)
    }

    private func positions(count: Int, length: CGFloat) -> [CGFloat] {
        let count = min(max(count, Self.lineCountRange.lowerBound), Self.lineCountRange.upperBound)
        return (0..<count).map { CGFloat($0 + 1) * length / CGFloat(count + 1) }
    }
}

enum PrintCompositionGeometry {
    static let minimumItemSide: CGFloat = 12

    static func normalized(degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        let normalized = remainder < 0 ? remainder + 360 : remainder
        return abs(normalized - 360) < 0.0001 ? 0 : normalized
    }

    static func rotate(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    static func corner(
        _ corner: PrintCompositionCorner,
        of frame: CGRect,
        rotation: Double
    ) -> CGPoint {
        rotate(corner.point(in: frame), around: CGPoint(x: frame.midX, y: frame.midY), degrees: rotation)
    }

    static func boundingBox(of frame: CGRect, rotation: Double) -> CGRect {
        let points = PrintCompositionCorner.allCases.map { corner($0, of: frame, rotation: rotation) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min()!,
            y: ys.min()!,
            width: xs.max()! - xs.min()!,
            height: ys.max()! - ys.min()!
        )
    }

    static func fitted(aspect: CGFloat, rotation: Double = 0, in bounds: CGRect) -> CGRect {
        let unit = boundingBox(of: CGRect(x: 0, y: 0, width: aspect, height: 1), rotation: rotation)
        let height = min(bounds.width / unit.width, bounds.height / unit.height)
        let width = height * aspect
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func filled(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        let width = max(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func resized(
        _ frame: CGRect,
        corner: PrintCompositionCorner,
        to point: CGPoint,
        lockedRatio: CGFloat?,
        rotation: Double = 0
    ) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let localPoint = rotate(point, around: center, degrees: -rotation)
        let local = resizedUnrotated(frame, corner: corner, to: localPoint, lockedRatio: lockedRatio)
        let newCenter = rotate(
            CGPoint(x: local.midX, y: local.midY),
            around: center,
            degrees: rotation
        )
        return CGRect(
            x: newCenter.x - local.width / 2,
            y: newCenter.y - local.height / 2,
            width: local.width,
            height: local.height
        )
    }

    private static func resizedUnrotated(
        _ frame: CGRect,
        corner: PrintCompositionCorner,
        to point: CGPoint,
        lockedRatio: CGFloat?
    ) -> CGRect {
        let anchor = corner.opposite(in: frame)
        let dragWidth = corner.isLeft ? anchor.x - point.x : point.x - anchor.x
        let dragHeight = corner.isTop ? anchor.y - point.y : point.y - anchor.y

        var width: CGFloat
        var height: CGFloat
        if let lockedRatio {
            width = max(dragWidth, dragHeight * lockedRatio, minimumItemSide * max(1, lockedRatio))
            height = width / lockedRatio
        } else {
            width = max(dragWidth, minimumItemSide)
            height = max(dragHeight, minimumItemSide)
        }

        return CGRect(
            x: corner.isLeft ? anchor.x - width : anchor.x,
            y: corner.isTop ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    static func snappedResize(
        _ frame: CGRect,
        corner handle: PrintCompositionCorner,
        to point: CGPoint,
        lockedRatio: CGFloat?,
        rotation: Double,
        paper: CGSize,
        grid: PrintCompositionGrid,
        threshold: CGFloat
    ) -> (frame: CGRect, guides: PrintSnapGuides) {
        let proposed = resized(frame, corner: handle, to: point, lockedRatio: lockedRatio, rotation: rotation)
        let moving = corner(handle, of: proposed, rotation: rotation)
        let vertical = nearestSnap(edges: [moving.x], targets: grid.verticalLines(in: paper), threshold: threshold)
        let horizontal = nearestSnap(edges: [moving.y], targets: grid.horizontalLines(in: paper), threshold: threshold)
        var candidates: [CGPoint] = []

        if lockedRatio != nil {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let anchor = rotate(handle.opposite(in: frame), around: center, degrees: rotation)
            let dx = moving.x - anchor.x
            let dy = moving.y - anchor.y
            if let vertical, abs(dx) > 0.0001 {
                let scale = (vertical.target - anchor.x) / dx
                if scale > 0 { candidates.append(CGPoint(x: vertical.target, y: anchor.y + dy * scale)) }
            }
            if let horizontal, abs(dy) > 0.0001 {
                let scale = (horizontal.target - anchor.y) / dy
                if scale > 0 { candidates.append(CGPoint(x: anchor.x + dx * scale, y: horizontal.target)) }
            }
        } else if vertical != nil || horizontal != nil {
            candidates.append(CGPoint(x: vertical?.target ?? moving.x, y: horizontal?.target ?? moving.y))
        }

        var best = (frame: proposed, guides: PrintSnapGuides())
        var bestDistance = CGFloat.infinity
        for candidate in candidates {
            let result = resized(frame, corner: handle, to: candidate, lockedRatio: lockedRatio, rotation: rotation)
            let actual = corner(handle, of: result, rotation: rotation)
            let distance = hypot(actual.x - moving.x, actual.y - moving.y)
            guard distance <= threshold * 1.5, distance < bestDistance else { continue }
            let guides = PrintSnapGuides(
                vertical: vertical.flatMap { abs(actual.x - $0.target) < 0.001 ? $0.target : nil },
                horizontal: horizontal.flatMap { abs(actual.y - $0.target) < 0.001 ? $0.target : nil }
            )
            guard guides.vertical != nil || guides.horizontal != nil else { continue }
            best = (result, guides)
            bestDistance = distance
        }
        return best
    }

    static func snapped(
        _ frame: CGRect,
        rotation: Double = 0,
        paper: CGSize,
        threshold: CGFloat,
        grid: PrintCompositionGrid? = nil
    ) -> (frame: CGRect, guides: PrintSnapGuides) {
        var frame = frame
        var guides = PrintSnapGuides()
        let bounds = boundingBox(of: frame, rotation: rotation)

        if let snap = nearestSnap(
            edges: [bounds.minX, bounds.midX, bounds.maxX],
            targets: grid?.verticalLines(in: paper) ?? [0, paper.width / 2, paper.width],
            threshold: threshold
        ) {
            frame.origin.x += snap.delta
            guides.vertical = snap.target
        }

        if let snap = nearestSnap(
            edges: [bounds.minY, bounds.midY, bounds.maxY],
            targets: grid?.horizontalLines(in: paper) ?? [0, paper.height / 2, paper.height],
            threshold: threshold
        ) {
            frame.origin.y += snap.delta
            guides.horizontal = snap.target
        }

        return (frame, guides)
    }

    static func applying(
        ratio: CGFloat?,
        to frame: CGRect,
        rotation: Double = 0,
        paper: CGSize
    ) -> CGRect {
        guard let ratio else { return frame }

        let area = frame.width * frame.height
        var width = (area * ratio).squareRoot()
        var height = width / ratio
        let bounds = boundingBox(of: CGRect(x: 0, y: 0, width: width, height: height), rotation: rotation)
        let fitScale = min(paper.width / bounds.width, paper.height / bounds.height, 1)
        width *= fitScale
        height *= fitScale

        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func nearestSnap(
        edges: [CGFloat],
        targets: [CGFloat],
        threshold: CGFloat
    ) -> (delta: CGFloat, target: CGFloat)? {
        var best: (delta: CGFloat, target: CGFloat)?

        for edge in edges {
            for target in targets {
                let delta = target - edge
                guard abs(delta) <= threshold else { continue }
                if best == nil || abs(delta) < abs(best!.delta) {
                    best = (delta, target)
                }
            }
        }

        return best
    }
}
