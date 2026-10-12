import SwiftUI

struct MenuBarLabel: View {
    let listenerStore: ProcessListenerStore

    var body: some View {
        let count = listenerStore.listeners.count
        Label {
            if count > 0 {
                Text(String(count))
            }
        } icon: {
            Image(systemName: "circle.hexagongrid")
        }
        .accessibilityLabel("visualize, \(count) listening ports")
    }
}
