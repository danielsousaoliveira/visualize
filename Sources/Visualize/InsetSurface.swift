import SwiftUI

struct InsetSurface<Content: View>: View {
    var inset = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(inset ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(inset ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
