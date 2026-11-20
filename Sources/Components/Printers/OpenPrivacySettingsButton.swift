import AppKit
import SwiftUI

struct OpenPrivacySettingsButton: View {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")

    var body: some View {
        Button {
            if let url = Self.settingsURL { NSWorkspace.shared.open(url) }
        } label: {
            Text("Open Privacy & Security")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrettyPrintTileButtonStyle(size: .row))
        .prettyPrintHoverHighlight(.accent)
        .prettyPrintButtonCursor()
    }
}
