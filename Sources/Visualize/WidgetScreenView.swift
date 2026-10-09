import AppKit

final class WidgetScreenView: NSView {
    var onHeight: ((CGFloat) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        reportHeight()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenChanged(_ notification: Notification) {
        reportHeight()
    }

    private func reportHeight() {
        guard let screen = window?.screen else { return }
        let height = screen.visibleFrame.height
        DispatchQueue.main.async { [weak self] in self?.onHeight?(height) }
    }
}
