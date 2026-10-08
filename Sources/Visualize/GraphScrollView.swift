import SwiftUI
import AppKit

struct GraphScrollView: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollSurface {
        let view = ScrollSurface()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollSurface, context: Context) {
        view.onScroll = onScroll
    }

}
