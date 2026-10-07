import Foundation

struct ScanInfra: Codable, Hashable {
    var id: String
    var kind: ScanInfraKind
    var usedBy: [String]
    var providedBy: String?
    var evidence: [String]
    var host: String?
    var port: Int?

    static func id(kind: ScanInfraKind, index: Int) -> String {
        index == 0 ? "infra:\(kind.rawValue)" : "infra:\(kind.rawValue)-\(index + 1)"
    }
}

extension ScanInfra {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try container.decode(ScanInfraKind.self, forKey: .kind)
        usedBy = try container.decode([String].self, forKey: .usedBy)
        providedBy = try container.decodeIfPresent(String.self, forKey: .providedBy)
        evidence = try container.decode([String].self, forKey: .evidence)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
    }
}

extension Array where Element == ScanInfra {
    func fillingMissingIds() -> [ScanInfra] {
        var countByKind: [ScanInfraKind: Int] = [:]
        return map { entry in
            let index = countByKind[entry.kind, default: 0]
            countByKind[entry.kind] = index + 1
            guard entry.id.isEmpty else { return entry }
            var filled = entry
            filled.id = ScanInfra.id(kind: entry.kind, index: index)
            return filled
        }
    }
}
