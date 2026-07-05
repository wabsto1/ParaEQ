import SwiftUI

// Native .help() tooltips are unreliable inside MenuBarExtra windows
// (non-activating accessory panels often never trigger NSToolTip). The
// helpHint modifier keeps .help() for accessibility, and additionally
// publishes the text to a shared HintState on hover, which EQView renders
// in a fixed hint bar at the bottom of the popover.

@Observable
final class HintState {
    var text: String?
}

private struct HelpHintModifier: ViewModifier {
    @Environment(HintState.self) private var hints: HintState?
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { hovering in
                guard let hints else { return }
                if hovering {
                    hints.text = text
                } else if hints.text == text {
                    hints.text = nil
                }
            }
    }
}

extension View {
    /// Tooltip that works in menu-bar panels: native .help() plus the
    /// shared hover hint bar.
    func helpHint(_ text: String) -> some View {
        modifier(HelpHintModifier(text: text))
    }
}
