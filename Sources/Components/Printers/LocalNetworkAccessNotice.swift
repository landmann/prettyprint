import SwiftUI

struct LocalNetworkAccessNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In Privacy & Security, click Local Network and turn on PrettyPrint.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OpenPrivacySettingsButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
