import AppKit

let bundleIdentifier = CommandLine.arguments[1]
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
for application in applications {
    guard application.terminate() else {
        fputs("Could not request quit. Quit visualize, then run pnpm dev again.\n", stderr)
        exit(1)
    }
}
if !applications.isEmpty {
    print("Waiting for visualize to quit. Resolve any running-services dialog in the app.")
    let deadline = Date().addingTimeInterval(60)
    while applications.contains(where: { !$0.isTerminated }) {
        guard Date() < deadline else {
            fputs("visualize is still running. Quit the app, then run pnpm dev again.\n", stderr)
            exit(1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
