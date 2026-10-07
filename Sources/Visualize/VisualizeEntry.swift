import Foundation
import Darwin

@main
struct VisualizeEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--drain-service-output"] {
            ServiceOutputDrainer.run()
            return
        }
        VisualizeApp.main()
    }
}
