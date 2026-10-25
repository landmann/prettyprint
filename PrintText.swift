import AppKit

enum PrintTextFont: String, CaseIterable, Codable, Identifiable {
    case typewriter = "AmericanTypewriter"
    case helvetica = "Helvetica"
    case timesNewRoman = "TimesNewRomanPSMT"
    case poppins = "Poppins-Regular"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .typewriter: "Typewriter"
        case .helvetica: "Helvetica"
        case .timesNewRoman: "Times New Roman"
        case .poppins: "Poppins"
        }
    }
}

struct PrintText: Codable, Equatable {
    static let fontSizeRange: ClosedRange<CGFloat> = 4...300
    var string = ""
    var font: PrintTextFont = .helvetica
    var fontSize: CGFloat = 24

    var title: String {
        let line = string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Text" : line
    }

    var isValid: Bool { fontSize.isFinite && fontSize > 0 }
}

@MainActor
enum PrintTextDrawing {
    private static func layout(_ text: PrintText, size: CGSize) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text.string, attributes: [
            .font: NSFont(name: text.font.rawValue, size: text.fontSize) ?? NSFont.systemFont(ofSize: text.fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return (storage, manager, container)
    }

    static func requiredHeight(_ text: PrintText, width: CGFloat) -> CGFloat {
        let (storage, manager, container) = layout(text, size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        manager.ensureLayout(for: container)
        return withExtendedLifetime(storage) { ceil(manager.usedRect(for: container).height) }
    }

    static func draw(_ text: PrintText, in rect: CGRect, context: CGContext, flipped: Bool = false) {
        guard !text.string.isEmpty else { return }
        let (storage, manager, container) = layout(text, size: rect.size)
        let glyphs = manager.glyphRange(for: container)
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: flipped ? rect.minY : rect.maxY)
        if !flipped { context.scaleBy(x: 1, y: -1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        withExtendedLifetime(storage) {
            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
