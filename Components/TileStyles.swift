import AppKit
import SwiftUI

let prettyPrintHoverAnimation = Animation.easeOut(duration: 0.08)

struct PrettyPrintTileTint {
    let fill: Color
    let text: Color

    static let destructive = PrettyPrintTileTint(
        fill: .red,
        text: Color(red: 1, green: 0.66, blue: 0.64)
    )
}

struct PrettyPrintTileFill: View {
    static let top = Color(white: 0.36)
    static let bottom = Color(white: 0.29)
    static let pressed = Color(white: 0.24)

    var cornerRadius: CGFloat = 0
    var isPressed = false
    var tint: PrettyPrintTileTint?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }

    private var fill: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint.fill.opacity(isPressed ? 0.5 : 0.36))
        }
        if isPressed {
            return AnyShapeStyle(Self.pressed)
        }
        return AnyShapeStyle(LinearGradient(colors: [Self.top, Self.bottom], startPoint: .top, endPoint: .bottom))
    }
}

struct PrettyPrintTileButtonStyle: ButtonStyle {
    enum Size {
        case row
        case icon
        case small

        var height: CGFloat {
            switch self {
            case .row: 24
            case .icon: 28
            case .small: 20
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .row: 12
            case .icon: 10
            case .small: 7
            }
        }

        var cornerRadius: CGFloat {
            self == .small ? 5 : 6
        }

        var font: Font? {
            self == .small ? .system(size: 11, weight: .medium) : nil
        }
    }

    let size: Size
    var tint: PrettyPrintTileTint?

    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintTileButton(configuration: configuration, size: size, tint: tint)
    }
}

struct PrettyPrintTileButton: View {
    let configuration: ButtonStyle.Configuration
    let size: PrettyPrintTileButtonStyle.Size
    let tint: PrettyPrintTileTint?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(tint.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.primary))
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(
                PrettyPrintTileFill(cornerRadius: size.cornerRadius, isPressed: configuration.isPressed, tint: tint)
            )
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
    }
}

enum PrettyPrintHoverTone {
    case accent
    case row
    case selection
    case primary
    case destructive

    var color: Color {
        switch self {
        case .accent:
            .accentColor
        case .row, .selection, .primary:
            .blue
        case .destructive:
            .red
        }
    }

    var fillColor: Color {
        switch self {
        case .primary:
            .white
        case .accent, .row, .selection, .destructive:
            color
        }
    }

    var fillOpacity: Double {
        switch self {
        case .accent:
            0.09
        case .row:
            0.14
        case .selection:
            0.08
        case .primary:
            0.12
        case .destructive:
            0.08
        }
    }

    var borderOpacity: Double {
        switch self {
        case .row:
            0
        case .accent:
            0.34
        case .selection:
            0.28
        case .primary:
            0.7
        case .destructive:
            0.3
        }
    }

    var shadowOpacity: Double {
        switch self {
        case .row:
            0
        case .accent:
            0.16
        case .selection:
            0.12
        case .primary:
            0.28
        case .destructive:
            0.16
        }
    }

    var animation: Animation {
        self == .row ? .easeInOut(duration: 0.18) : prettyPrintHoverAnimation
    }
}

struct PrettyPrintHoverHighlight<HighlightShape: InsettableShape>: ViewModifier {
    let tone: PrettyPrintHoverTone
    let shape: HighlightShape

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isActive: Bool {
        isEnabled && isHovering
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(tone.fillColor.opacity(isActive ? tone.fillOpacity : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(tone.color.opacity(isActive ? tone.borderOpacity : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: tone.color.opacity(isActive ? tone.shadowOpacity : 0),
                radius: isActive ? 6 : 0,
                y: isActive ? 2 : 0
            )
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isHovering = false
                }
            }
            .animation(reduceMotion ? nil : tone.animation, value: isActive)
    }
}

struct PrettyPrintButtonCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                TapGesture().onEnded {
                    DispatchQueue.main.async {
                        guard let window = NSApp.keyWindow,
                              !(window.firstResponder is NSTextView) else { return }
                        PrettyPrintPointerFocus.dismiss(in: window)
                    }
                }
            )
            .onContinuousHover { phase in
                guard isEnabled else {
                    isHovering = false
                    NSCursor.arrow.set()
                    return
                }

                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.pointingHand.set()
                case .ended:
                    isHovering = false
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isHovering = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.arrow.set()
                }
            }
    }
}

extension View {
    func prettyPrintHoverHighlight(
        _ tone: PrettyPrintHoverTone,
        cornerRadius: CGFloat = 6
    ) -> some View {
        prettyPrintHoverHighlight(
            tone,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    func prettyPrintHoverHighlight(
        _ tone: PrettyPrintHoverTone,
        in shape: some InsettableShape
    ) -> some View {
        modifier(PrettyPrintHoverHighlight(tone: tone, shape: shape))
    }

    func prettyPrintButtonCursor() -> some View {
        modifier(PrettyPrintButtonCursor())
    }
}
