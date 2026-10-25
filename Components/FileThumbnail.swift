import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileThumbnailView: View {
    let url: URL
    var size: CGFloat = 68
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: url) {
                image = nil
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: size, height: size),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                   !Task.isCancelled {
                    image = thumbnail.nsImage
                }
            }
    }
}
