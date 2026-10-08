import SwiftUI
import AppKit

struct GraphScrollView: NSViewRepresentable {
    var onMagnify: (CGFloat) -> Void
    var onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollSurface {
        let view = ScrollSurface()
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollSurface, context: Context) {
        view.onMagnify = onMagnify
        view.onScroll = onScroll
    }

}
