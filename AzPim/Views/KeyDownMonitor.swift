import AppKit
import AzPimCore
import SwiftUI

/// Hands the navigation keys (↑ ↓ ↩ ⌘↩ ⇥ ⌫ ⌘⌫ esc) of the window hosting this view to `handler` before the focused
/// view sees them: a text field's field editor would otherwise take ↑ ↓ ↩ ⇥ itself. A key the handler returns false
/// for goes on as usual (the search field still types, deletes and clears). Other windows (popovers) are left alone.
struct KeyDownMonitor: NSViewRepresentable {
    let handler: (PaletteKey) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handler = handler
    }

    final class MonitorView: NSView {
        var handler: ((PaletteKey) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      let key = Self.key(for: event), self.handler?(key) == true else { return event }
                return nil
            }
        }

        static func key(for event: NSEvent) -> PaletteKey? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = flags.contains(.command)
            switch Int(event.keyCode) {
            case 126: return .upArrow
            case 125: return .downArrow
            case 36, 76: return command ? .commandReturn : .returnKey
            case 48: return flags.isDisjoint(with: [.shift, .command, .control, .option]) ? .tab : nil
            case 51: return command ? .commandDelete : .delete
            case 53: return .escape
            default: return nil
            }
        }
    }
}

/// Highlight of the row the keyboard selected.
struct KeyboardSelection: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : Color.clear)
                .padding(.horizontal, -6)
        )
    }
}

extension View {
    func keyboardSelected(_ selected: Bool) -> some View { modifier(KeyboardSelection(selected: selected)) }
}
