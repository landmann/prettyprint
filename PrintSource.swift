import AppKit
import ImageIO
import PDFKit
import QuickLookThumbnailing

@MainActor
final class PrintSource {
    private enum Content {
        case pdf(PDFDocument)
        case image(NSImage)
    }

    private static let maximumRasterPixels: CGFloat = 4000
    private static let previewPixels: CGFloat = 1600

    let url: URL
    private let content: Content
    private var previewCache: [Int: NSImage] = [:]

    private init(url: URL, content: Content) {
        self.url = url
        self.content = content
    }

    static func load(_ url: URL) async -> PrintSource? {
        if let document = PDFDocument(url: url), document.pageCount > 0 {
            return PrintSource(url: url, content: .pdf(document))
        }

        if let image = orientedImage(at: url) {
            return PrintSource(url: url, content: .image(image))
        }

        if let image = await quickLookImage(at: url) {
            return PrintSource(url: url, content: .image(image))
        }

        return nil
    }

    var pageCount: Int {
        switch content {
        case .pdf(let document): document.pageCount
        case .image: 1
        }
    }

    func pageSize(_ index: Int) -> CGSize {
        switch content {
        case .pdf(let document):
            guard let page = document.page(at: clampedPage(index)) else { return CGSize(width: 1, height: 1) }
            let bounds = page.bounds(for: .cropBox)
            return page.rotation % 180 == 0
                ? bounds.size
                : CGSize(width: bounds.height, height: bounds.width)
        case .image(let image):
            return image.size
        }
    }

    func aspect(_ index: Int) -> CGFloat {
        let size = pageSize(index)
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    func previewImage(_ index: Int) -> NSImage {
        let index = clampedPage(index)
        if let cached = previewCache[index] {
            return cached
        }

        let image: NSImage
        switch content {
        case .pdf(let document):
            let size = pageSize(index)
            let scale = Self.previewPixels / max(size.width, size.height)
            image = document.page(at: index)?.thumbnail(
                of: CGSize(width: size.width * scale, height: size.height * scale),
                for: .cropBox
            ) ?? NSImage()
        case .image(let sourceImage):
            image = sourceImage
        }

        previewCache[index] = image
        return image
    }

    func draw(_ index: Int, in rect: CGRect, context: CGContext) {
        switch content {
        case .pdf(let document):
            guard let page = document.page(at: clampedPage(index)) else { return }
            let size = pageSize(index)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
        case .image(let image):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func clampedPage(_ index: Int) -> Int {
        min(max(index, 0), pageCount - 1)
    }

    private static func orientedImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumRasterPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    private static func quickLookImage(at url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: previewPixels, height: previewPixels),
            scale: 1,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
            .nsImage
    }
}

enum PrintCompositionRenderError: Error {
    case contextUnavailable
}

@MainActor
enum PrintCompositionRenderer {
    static func render(
        _ pages: [PrintComposition],
        sources: [URL: PrintSource],
        to url: URL
    ) throws {
        guard let firstPage = pages.first else {
            throw PrintCompositionRenderError.contextUnavailable
        }
        var mediaBox = firstPage.paper.bounds
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw PrintCompositionRenderError.contextUnavailable
        }

        for composition in pages {
            var bounds = composition.paper.bounds
            let box = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            draw(composition, sources: sources, context: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(
        _ composition: PrintComposition,
        sources: [URL: PrintSource],
        context: CGContext
    ) {
        for item in composition.items {
            let center = CGPoint(
                x: item.frame.midX,
                y: composition.paper.size.height - item.frame.midY
            )
            let frame = CGRect(
                x: -item.frame.width / 2,
                y: -item.frame.height / 2,
                width: item.frame.width,
                height: item.frame.height
            )
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: -item.rotation * .pi / 180)
            context.clip(to: frame)
            switch item.content {
            case .text(let text):
                PrintTextDrawing.draw(text, in: frame, context: context)
            case .file(let url):
                if let source = sources[url] {
                    let contentRect = PrintCompositionGeometry.filled(aspect: source.aspect(item.pageIndex), in: frame)
                    source.draw(item.pageIndex, in: contentRect, context: context)
                }
            }
            context.restoreGState()
        }
    }
}
