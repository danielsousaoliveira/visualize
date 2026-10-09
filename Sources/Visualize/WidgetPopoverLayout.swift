import SwiftUI

struct WidgetPopoverLayout: Layout {
    let maxHeight: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let footer = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let available = max(60, maxHeight - footer.height - spacing)
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: available))
        return CGSize(width: max(content.width, footer.width), height: min(content.height, available) + spacing + footer.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let footer = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let height = max(0, bounds.height - footer.height - spacing)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - footer.height), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: footer.height))
    }
}
