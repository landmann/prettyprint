import AppKit
import SwiftUI

struct ComposerTextPreview: NSViewRepresentable {
    let text: PrintText
    let scale: CGFloat

    func makeNSView(context: Context) -> TextView { TextView() }

    func updateNSView(_ view: TextView, context: Context) {
        view.text = text
        view.scale = scale
        view.needsDisplay = true
    }

    final class TextView: NSView {
        var text = PrintText()
        var scale: CGFloat = 1
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext, scale > 0 else { return }
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            PrintTextDrawing.draw(
                text,
                in: CGRect(x: 0, y: 0, width: bounds.width / scale, height: bounds.height / scale),
                context: context,
                flipped: true
            )
            context.restoreGState()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
