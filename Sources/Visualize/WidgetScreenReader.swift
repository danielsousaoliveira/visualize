import AppKit
import SwiftUI

struct WidgetScreenReader: NSViewRepresentable {
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> WidgetScreenView {
        let view = WidgetScreenView()
        view.onHeight = onHeight
        return view
    }

    func updateNSView(_ view: WidgetScreenView, context: Context) {
        view.onHeight = onHeight
        view.needsLayout = true
    }
}
