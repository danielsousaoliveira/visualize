import SwiftUI
import AppKit

struct ServiceLogView: View {
    let log: ServiceLog
    let docker: DockerRun?
    let directory: String
    @State private var search = ""
    @State private var match = 0
    @State private var following = true
    @State private var jump = 0
    private var follower: DockerLogFollower { log.dockerFollower }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search logs", text: $search)
                    .onChange(of: search) { match = 0; following = false }
                Button("Previous", systemImage: "chevron.up") { match -= 1; following = false }
                    .disabled(search.isEmpty)
                Button("Next", systemImage: "chevron.down") { match += 1; following = false }
                    .disabled(search.isEmpty)
            }
            HStack {
                Button("Clear") { log.clear() }
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                }
                Button("Open log file") {
                    Task {
                        log.error = await log.writer.flush()
                        if log.error == nil { NSWorkspace.shared.activateFileViewerSelecting([log.writer.url]) }
                    }
                }
            }
            LogTextView(lines: log.lines, revision: log.revision, search: search, match: match, jump: jump, following: $following)
                .frame(height: 280)
                .overlay {
                    if log.lines.isEmpty { Text("Waiting for service output…").foregroundStyle(.secondary).allowsHitTesting(false) }
                }
            HStack {
                Text("\(log.lines.count) lines").font(.caption).foregroundStyle(.secondary)
                if let error = log.error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                if !following { Button("Jump to latest") { following = true; jump += 1 } }
            }
        }
        .onAppear { if let docker { follower.start(docker, directory: directory, log: log) } }
        .onChange(of: docker?.containerIDs) {
            if let docker { follower.start(docker, directory: directory, log: log) }
            else { follower.stop() }
        }
        .onDisappear { follower.stop() }
    }
}
