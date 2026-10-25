import SwiftUI

let prettyPrintDropBlue = Color(red: 0.38, green: 0.66, blue: 1)

struct PrettyPrintFileDropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintFileDropButton(configuration: configuration)
    }
}

struct PrettyPrintFileDropButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(
                configuration.isPressed ? Color.primary : prettyPrintDropBlue.opacity(isHovering ? 1 : 0.85)
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        prettyPrintDropBlue.opacity(
                            configuration.isPressed ? 0.22 : isHovering ? 0.14 : 0.07
                        )
                    )
            )
            .onHover { isHovering = $0 }
            .animation(prettyPrintHoverAnimation, value: isHovering)
    }
}
