import Foundation

enum ScanConnectionKind: String, Codable, Hashable {
    case dependsOn = "depends_on"
    case envURL = "env-url"
    case usesInfra = "uses-infra"
    case workspaceDep = "workspace-dep"
}
