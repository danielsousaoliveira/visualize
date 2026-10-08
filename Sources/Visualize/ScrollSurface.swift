import AppKit

final class ScrollSurface: NSView {
    var onMagnify: ((CGFloat) -> Void)?
    var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.contains(.command))
    }
}
