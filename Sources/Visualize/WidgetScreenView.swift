import AppKit

final class WidgetScreenView: NSView {
    var onHeight: ((CGFloat) -> Void)?
    private var chromeHeight: CGFloat?
    private var anchorTop: CGFloat?
    private var resizing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        chromeHeight = nil
        anchorTop = nil
        guard let window else { return }
        reportHeight()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(opened), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    override func layout() {
        super.layout()
        resizeWindow()
    }

    @objc private func opened(_ notification: Notification) {
        anchorTop = nil
        resizeWindow()
    }

    @objc private func screenChanged(_ notification: Notification) {
        anchorTop = nil
        reportHeight()
        resizeWindow()
    }

    private func resizeWindow() {
        guard !resizing, let window, window.isVisible, let screen = window.screen, bounds.height > 0 else { return }
        let frame = window.frame
        if chromeHeight == nil { chromeHeight = max(0, frame.height - bounds.height) }
        if anchorTop == nil { anchorTop = min(frame.maxY, screen.visibleFrame.maxY) }
        let height = min(bounds.height + (chromeHeight ?? 0), screen.visibleFrame.height)
        let top = min(anchorTop ?? frame.maxY, screen.visibleFrame.maxY)
        let next = NSRect(x: frame.minX, y: max(screen.visibleFrame.minY, top - height), width: frame.width, height: height)
        guard abs(next.height - frame.height) > 0.5 || abs(next.minY - frame.minY) > 0.5 else { return }
        resizing = true
        defer { resizing = false }
        window.disableScreenUpdatesUntilFlush()
        window.setFrame(next, display: false, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.invalidateShadow()
    }

    private func reportHeight() {
        guard let screen = window?.screen else { return }
        let height = screen.visibleFrame.height
        DispatchQueue.main.async { [weak self] in self?.onHeight?(height) }
    }
}
