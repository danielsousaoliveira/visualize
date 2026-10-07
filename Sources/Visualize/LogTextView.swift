import SwiftUI
import AppKit

struct LogTextView: NSViewRepresentable {
    let lines: [LogLine]
    let revision: Int
    let search: String
    let match: Int
    let jump: Int
    @Binding var following: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let text = NSTextView(frame: .zero)
        text.setAccessibilityLabel("Service log output")
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled(scroll) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        render(scroll, coordinator: context.coordinator)
    }

    func render(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        guard let text = scroll.documentView as? NSTextView else { return }
        let changed = coordinator.revision != revision || coordinator.search != search
        let navigating = coordinator.match != match || coordinator.search != search
        let jumping = coordinator.jump != jump
        coordinator.updating = true
        defer { coordinator.updating = false }
        let origin = scroll.contentView.bounds.origin
        if changed {
            let content = NSMutableAttributedString()
            for line in lines {
                content.append(NSAttributedString(string: (line.isError ? "stderr │ " : "") + line.text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: line.isError ? NSColor.systemRed : NSColor.textColor]))
            }
            coordinator.matches = []
            if !search.isEmpty {
                let string = content.string as NSString
                var range = NSRange(location: 0, length: string.length)
                while range.length > 0 {
                    let found = string.range(of: search, options: .caseInsensitive, range: range)
                    if found.location == NSNotFound { break }
                    coordinator.matches.append(found)
                    content.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: found)
                    range = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
                }
            }
            text.textStorage?.setAttributedString(content)
            if !following { scroll.contentView.scroll(to: origin) }
        }
        if navigating, !coordinator.matches.isEmpty {
            let index = ((match % coordinator.matches.count) + coordinator.matches.count) % coordinator.matches.count
            let range = coordinator.matches[index]
            text.setSelectedRange(range)
            text.scrollRangeToVisible(range)
        } else if following && (changed || jumping) {
            text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
        }
        coordinator.revision = revision
        coordinator.search = search
        coordinator.match = match
        coordinator.jump = jump
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor
    final class Coordinator {
        var parent: LogTextView
        var observer: NSObjectProtocol?
        var updating = false
        var revision = -1
        var search = ""
        var match = 0
        var jump = 0
        var matches: [NSRange] = []

        init(_ parent: LogTextView) { self.parent = parent }

        func scrolled(_ scroll: NSScrollView) {
            guard !updating, let document = scroll.documentView else { return }
            let atBottom = scroll.contentView.bounds.maxY >= document.bounds.maxY - 8
            if parent.following && !atBottom {
                DispatchQueue.main.async { [weak self] in self?.parent.following = false }
            }
        }
    }
}
