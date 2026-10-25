import SwiftUI

struct PrettyPrintCopyStepper: View {
    let copies: Int
    let isPrinting: Bool
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard copies > QueuedDocument.minimumCopies else { return }
                onChange(copies - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(
                PrettyPrintCopyStepperButtonStyle(
                    isAtLimit: isPrinting || copies <= QueuedDocument.minimumCopies
                )
            )
            .accessibilityLabel("Decrease copies")
            .help("Decrease copies")
            .prettyPrintButtonCursor()
            .disabled(isPrinting)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)

            Text("\(copies)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 26)
                .accessibilityLabel("\(copies) \(copies == 1 ? "copy" : "copies")")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)

            Button {
                guard copies < QueuedDocument.maximumCopies else { return }
                onChange(copies + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(
                PrettyPrintCopyStepperButtonStyle(
                    isAtLimit: isPrinting || copies >= QueuedDocument.maximumCopies
                )
            )
            .accessibilityLabel("Increase copies")
            .help("Increase copies")
            .prettyPrintButtonCursor()
            .disabled(isPrinting)
        }
        .padding(2)
        .frame(width: 84, height: 26)
        .background(
            PrettyPrintTileFill(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct PrettyPrintCopyStepperButtonStyle: ButtonStyle {
    let isAtLimit: Bool

    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintCopyStepperButton(
            configuration: configuration,
            isAtLimit: isAtLimit
        )
    }
}

struct PrettyPrintCopyStepperButton: View {
    let configuration: ButtonStyle.Configuration
    let isAtLimit: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isAtLimit ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.accentColor.opacity(0.2)
                            : isHovering && !isAtLimit
                                ? Color.accentColor.opacity(0.1)
                                : .clear
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(prettyPrintHoverAnimation, value: isHovering)
    }
}
