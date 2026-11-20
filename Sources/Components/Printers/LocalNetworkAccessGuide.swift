import AppKit
import SwiftUI

struct LocalNetworkAccessGuide: View {
    let appIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let PrettyPrint find your printers")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                badge(1)
                OpenPrivacySettingsButton()
            }
            step(2, "Click Local Network") {
                SettingsRowIllustration(title: "Local Network") {
                    Image(systemName: "network")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } trailing: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            step(3, "Turn on PrettyPrint") {
                SettingsRowIllustration(title: "PrettyPrint") {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                } trailing: {
                    SwitchIllustration()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder detail: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                badge(number)
                Text(title)
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
            detail()
                .padding(.leading, 26)
        }
    }

    private func badge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .frame(width: 18, height: 18)
            .background(Color.white.opacity(0.14), in: Circle())
    }
}

private struct SettingsRowIllustration<Icon: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(title)
                .font(.caption)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        }
        .accessibilityHidden(true)
    }
}

private struct SwitchIllustration: View {
    var body: some View {
        Capsule()
            .fill(Color.green)
            .frame(width: 28, height: 16)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 2)
            }
    }
}
