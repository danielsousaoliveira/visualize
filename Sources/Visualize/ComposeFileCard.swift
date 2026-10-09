import SwiftUI

struct ComposeFileCard: View {
    let file: String
    let result: ScanResult

    private var services: [ScanComposeService] {
        let names = Set(result.services.compactMap { service in
            service.runModes.compose.composeFile == file ? service.runModes.compose.serviceName : nil
        })
        return result.composeServices.filter {
            if let composeFile = $0.composeFile { return composeFile == file }
            return names.contains($0.name) || (result.composeFiles.count == 1 && names.isEmpty)
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(file).font(.headline.monospaced())
                if services.isEmpty {
                    Text("No scanned services associated with this file").foregroundStyle(.secondary)
                }
                ForEach(services, id: \.name) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name).font(.callout.weight(.semibold))
                        if let image = service.image { Text("Image: \(image)") }
                        if let context = service.buildContext { Text("Build context: \(context)") }
                        if !service.ports.isEmpty {
                            Text("Ports (host → container): " + service.ports.map {
                                "\($0.host ?? "unpublished") → \($0.container)"
                            }.joined(separator: ", "))
                        }
                        if !service.dependsOn.isEmpty {
                            Text("Depends on: \(service.dependsOn.joined(separator: ", "))")
                        }
                    }
                    .font(.callout)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}
