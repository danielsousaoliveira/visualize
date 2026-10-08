import AppKit

final class ScrollSurface: NSView {
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.contains(.command))
    }
}
