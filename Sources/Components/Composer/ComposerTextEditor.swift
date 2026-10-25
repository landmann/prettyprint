import AppKit
import SwiftUI

struct ComposerTextEditor: NSViewRepresentable {
    static let height: CGFloat = 96
    @Binding var text: String
    let focusRequest: UUID?
    let onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let editor = TextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = CGSize(width: 8, height: 8)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = .width
        editor.minSize = CGSize(width: 0, height: Self.height)
        editor.setFrameSize(CGSize(width: scroll.contentSize.width, height: Self.height))
        editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Text content")
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? TextView else { return }
        if editor.string != text {
            editor.string = text
            editor.needsDisplay = true
        }
        editor.requestFocus(focusRequest)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        init(_ parent: ComposerTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? TextView else { return }
            editor.needsDisplay = true
            parent.text = editor.string
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }
    }

    final class TextView: NSTextView {
        private var pendingFocus: UUID?
        private var appliedFocus: UUID?

        func requestFocus(_ request: UUID?) {
            pendingFocus = request
            applyPendingFocus()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyPendingFocus()
        }

        private func applyPendingFocus() {
            guard window != nil, let request = pendingFocus, request != appliedFocus else { return }
            appliedFocus = request
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingFocus == request else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText() else { return }
            ("Type your text…" as NSString).draw(at: textContainerOrigin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}
