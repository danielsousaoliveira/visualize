import Foundation
import Darwin

struct PortOwner: Identifiable, Sendable {
    let port: Int
    let pid: Int32
    let name: String
    let uid: UInt32?
    let seconds: UInt64?
    let microseconds: UInt64?
    let workingDirectory: String?
    var containerID: String?
    var containerName: String?
    var composeProject: String?

    var id: String { "\(port):\(pid):\(containerID ?? "")" }
    var title: String {
        if let containerName { return "Port \(port) is in use by container \(containerName)" }
        return "Port \(port) is in use by \(name) (pid \(pid))"
    }

}
